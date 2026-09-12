import Foundation
import Synchronization

/// Microphone capture whose engine lives for one session, or for the whole run when the
/// user has asked for that. `start` holds the grant and watches the input device, and
/// brings the microphone to what `MicrophoneAtRest` says it does between presses. Under
/// the default, `shut`, it opens nothing, so a Mac with low-talker running and nobody
/// dictating shows no microphone in the menu bar; `beginSession` opens the microphone,
/// `endSession` closes it, and between the two the ring fills as before: a session is
/// still two positions on the ring.
///
/// What that costs is the look-back. A session's pre-roll reaches back over audio the
/// microphone was already capturing, and one opened at key-down has none behind it, so
/// the pre-roll clamps to nothing and the utterance starts where the microphone did. A
/// prepared microphone's first sample lands well inside the gap between deciding to press
/// a key and beginning to say a word, so a press followed by speech loses nothing; a
/// press made *during* a word loses the part of it that was said before the key went
/// down, and no microphone can be opened in the past.
///
/// That holds only because the microphone is readied before the press rather than at it.
/// Reaching a microphone costs far more than opening one already reached, and a press
/// that paid both was losing a third of a second off every utterance - so `start` readies
/// one while the app is idle, which opens no device and lights nothing, and the press
/// pays only the opening. What a press is allowed to miss is `warmUpAllowance`; what
/// reaching and opening each cost, and how the microphone is reached at all, is
/// `HALInput`'s.
///
/// `open` is the other side of that trade, and buying the look-back back is the whole of
/// what it does here: the engine started at `start` is never given up between presses, so
/// the ring is continuous and a press reaches back over real audio. Nothing in this file
/// decides which one is in force - `start` is told, and `rest` is the one place the answer
/// is read.
///
/// That argument covers the warm engine and nothing else, so the gap is measured rather
/// than assumed: `endSession` reads the stretch between the key going down and the first
/// sample anything captured, and a press missing more of it than `warmUpAllowance` comes
/// back partial instead of whole. Two things reach that door - the first press in a
/// process, which pays a cold launch, and a key-down the tap delivered late, which pays
/// whatever was ahead of it. Both are speech the speaker addressed to a shut microphone,
/// and a press that says so is one they can repeat; a sentence quietly missing its front
/// is not. [LAW:no-silent-failure]
///
/// The engine is disposable and the ring is not. A microphone is prepared against one
/// device and cannot be re-pointed at another, so a device change launches a new engine
/// by the same routine as opening one, and the ring, which lives here rather than in any
/// engine, carries across. What it carries across is spliced: no audio is captured
/// between the two engines, so the position the new one resumes at is kept and a session
/// that spans it is told its clip is not whole.
///
/// When the only input device is unplugged, the replacement cannot launch (there is
/// nothing to convert from) and capture is failed. A failed capture has no engine, so
/// the plug-back-in reaches it another way: the system default input device is watched
/// for the whole started period, and a change launches again wherever the engine is
/// failed - mid-press, or held at rest and dead. A shut one it leaves shut.
@MainActor
public final class AudioCapture {
    public enum State {
        case stopped
        /// Started, with no session open: the grant is held and the input device is
        /// watched, and the microphone is doing whatever the resting mode says.
        case listening
        /// A session is open, so the microphone is too.
        case running
        /// The engine stopped on its own, until a launch clears it - the input device
        /// changing, or the next press - or, under `shut`, a key-up closes it instead.
        case failed(any Error)
    }

    /// The gaps in capture since `start()`: how many, and how long without audio all
    /// together.
    public struct Outages: Sendable {
        public var count = 0
        public var total: Duration = .zero
    }

    /// An engine on the input device of its moment. The generation is what this engine's
    /// tap carries with a failure, so a failure from a replaced engine is recognized as
    /// stale (a counter, because a replaced engine's address can be reused).
    private struct Live {
        let dispose: Disposal
        let generation: Int
    }

    /// What the microphone is doing.
    private enum Engine {
        /// Nothing is running and macOS shows nothing.
        case shut
        case running(Live)
        /// The engine has been gone since `since`.
        case failed(any Error, since: ContinuousClock.Instant)
    }

    /// [LAW:types-are-the-program] The grant, the default-input watch and the resting mode
    /// exist exactly between `start()` and `stop()`, whatever the microphone is doing, so
    /// they live beside the engine rather than in optionals every reader would have to
    /// reconcile.
    private struct Started {
        let watch: Disposal
        let grant: MicrophoneGrant
        /// What the microphone does whenever no session is open. Fixed for this run of
        /// capture: it is what capture was started for, and a run started to hold the
        /// microphone open cannot become one that does not without giving the device up,
        /// which is `stop()` and a fresh `start()`.
        let atRest: MicrophoneAtRest
        var engine: Engine
        /// The microphone this run of capture opens, readied but not open. Held across
        /// presses because that is the whole of what makes `shut` affordable: what it
        /// cost to ready is spent once, while nobody is dictating, and a press pays only
        /// what it costs to open a microphone already reached.
        ///
        /// Replaced rather than re-pointed when the input device changes, because an
        /// input is prepared against one device. [LAW:one-source-of-truth] `AudioCapture`
        /// is the one place that learns the device changed, so it is the one place that
        /// decides a prepared input has gone stale.
        var prepared: any PreparedInput
        /// Whether a press is in flight. The engine's own state answered this while the
        /// microphone's lifetime was one session's; a resting mode that holds the engine
        /// across presses takes that reading away, so the fact is kept rather than
        /// inferred from a microphone that is now open for two different reasons.
        /// [FRAMING:representation]
        var sessionIsOpen = false
        /// The default input changed while a session was open, and readying against it was
        /// put off until the press ended rather than cutting the recording in flight.
        ///
        /// [LAW:no-ambient-temporal-coupling] The watch fires once and does not fire again
        /// until the default changes a second time, so a press that swallowed the one
        /// notification would leave every later press on the device that stopped being the
        /// default. Deferring the work is not dropping it, and this is where the deferral
        /// stands until it is paid - at the key-up, or sooner by anything that readies a
        /// microphone against the current default first. [LAW:single-enforcer] `ready` is
        /// the one place either happens.
        var readyAgainAtRest = false
    }

    private enum Phase {
        case stopped
        case started(Started)
    }

    /// The samples and where their positions sit in time. [LAW:no-ambient-temporal-coupling]
    /// One value under one lock: a position read off the timeline and a slice taken
    /// from the ring must not straddle a buffer that arrived between them.
    private struct Stream: Sendable {
        var ring: AudioRing
        var timeline: AudioTimeline
        /// The first position the engine now feeding the ring will write to. Everything
        /// before it was captured by an engine that has since stopped - a previous
        /// session's, or this one's before the input device changed under it - with a
        /// stretch of speech missing in between: nothing is captured while no engine is
        /// running, and positions advance only on capture, so the audio on either side
        /// of the break is spliced together with no seam in the samples to find it by.
        var continuousSince = 0
        /// The generation whose buffers this stream is the audio of. An engine's tap can
        /// deliver once more after `dispose()` returns, and that buffer belongs to a press
        /// the speaker has already let go of; appending it would move the positions the
        /// next press begins from. Read on the tap's queue, which cannot ask the main
        /// actor, so the answer lives here beside the samples it admits.
        /// [LAW:no-ambient-temporal-coupling]
        var accepting: Int?
        /// When the first sample delivered since the open session began was captured, and
        /// nothing once it is set: it dates that session's head, so a later engine's
        /// buffers must not re-date it. A microphone opened for the press is dated by the
        /// first sample it captures, which is after the key; one the resting mode was
        /// already holding is dated by a sample captured at or before the key, since its
        /// buffers were already running, and `AudioSession.unheard` answers zero for
        /// those. Empty means nothing has been delivered since the session began, which is
        /// a microphone that never opened for it at all - and which a held microphone can
        /// arrive at too, by dying quietly rather than by opening late.
        var openedForSession: HostTime?
    }

    /// The stream behind a lock, shared between the tap's queue and the main actor.
    private final class Shared: Sendable {
        let stream: Mutex<Stream>
        init(_ stream: Stream) { self.stream = Mutex(stream) }
    }

    private let hardware: any AudioHardware
    private let shared: Shared
    private var phase: Phase = .stopped
    private var generation = 0
    /// Microphones readied since this capture was made. What the staleness callback of each
    /// readied input carries, for the reason an engine's generation is carried: the watch
    /// behind it lives as long as the input does, a notification already posted when that
    /// input was let go still arrives, and the input it speaks about is not the one a press
    /// would open any more. Never reset - `start()` resets what it counts, and a counter that
    /// went back to zero would let the previous run's stragglers match.
    private var preparations = 0
    /// Running engines `replaceEngine` swapped in place since `start()`: the device
    /// changed, capture stayed running, and nothing failed. Not a claim that no audio was
    /// lost to them - the audio on either side of each one is spliced, which is what a
    /// session's `CapturedAudio` says and this count does not.
    public private(set) var deviceChanges = 0
    public private(set) var outages = Outages()

    nonisolated public static let defaultRetention: TimeInterval = 60

    /// How long the microphone may take to open after the key went down before the press
    /// is treated as having missed speech rather than as having warmed up.
    ///
    /// This is the number the epic traded the look-back for, so it is written down rather
    /// than tuned. What it is compared against is the whole stretch from the key going
    /// down to the first sample anything captured, which is everything opening a
    /// microphone costs and not only the last call of it - the distinction this number
    /// was once measured on the wrong side of, when a figure taken from after the engine
    /// was built was read as what a press pays.
    ///
    /// The allowance is 100 ms: two and a half times what a prepared press pays on this
    /// Mac, and well under the two ways a microphone actually opens late - one that was
    /// never readied, which costs 213 ms, and a key-down the tap delivered late, which
    /// costs whatever the handler ahead of it was doing (the epic measured a 43-character
    /// insert at about 1.2 s). Ordinary presses and missed speech are two populations that
    /// far apart, so the allowance never has to be retuned to keep an ordinary press whole.
    ///
    /// It is also what says the microphone may not be reached through AVAudioEngine, which
    /// cannot open one inside this. What a press pays, what the readying it skipped costs
    /// and what AVAudioEngine cost instead are measured in `HALInput`.
    /// [LAW:no-silent-failure]
    nonisolated public static let warmUpAllowance: TimeInterval = 0.1

    /// `origin` is when the first sample is expected: nothing has been captured yet,
    /// so the timeline starts on that prediction and the first buffer corrects it.
    public init(
        retaining duration: TimeInterval = defaultRetention,
        hardware: any AudioHardware = SystemAudioHardware(),
        startingAt origin: HostTime = .now
    ) {
        self.hardware = hardware
        shared = Shared(Stream(ring: AudioRing(retaining: duration), timeline: AudioTimeline(startingAt: origin)))
    }

    public var state: State {
        switch phase {
        case .stopped: .stopped
        case .started(let started):
            switch started.engine {
            case .failed(let error, _): .failed(error)
            // A running engine is a press's while one is in flight and the resting mode's
            // the rest of the time. `running` names the press, not the microphone: which
            // of the two is holding the device open is what `atRest` says.
            case .shut, .running: started.sessionIsOpen ? .running : .listening
            }
        }
    }

    /// What the microphone does between presses for the run of capture that is started,
    /// and nothing at all when none is. Read from here rather than from the config, so a
    /// reader is told what capture is doing rather than what a file asked for.
    /// [LAW:one-source-of-truth]
    public var atRest: MicrophoneAtRest? {
        guard case .started(let started) = phase else { return nil }
        return started.atRest
    }

    /// What to tell the user their microphone is doing, in one sentence.
    ///
    /// The resting mode alone cannot say it. That is what was asked for, and an engine
    /// that died while nobody was pressing anything leaves it asked for and untrue - so a
    /// surface reading the mode alone reports a live device for as long as the app runs.
    /// [FRAMING:representation] The mode is the map and the engine is the territory, and
    /// this is the one place they are read together.
    ///
    /// It matters most where the failure is quietest. Under `shut` the next press
    /// relaunches a dead engine and the user learns within one hold; under `open` nobody
    /// presses for hours, and this is the only surface that could say the device is gone.
    /// [LAW:no-silent-failure]
    public var doing: String {
        guard case .started(let started) = phase else { return "not being captured" }
        switch started.engine {
        case .shut, .running: return "\(started.atRest)"
        case .failed(let error, _): return "\(started.atRest), but it stopped: \(error)"
        }
    }

    /// Takes the microphone for a session - opening one, or using the one the resting mode
    /// is already holding - and marks where the session begins: the position capture had
    /// reached when `moment` passed, with the pre-roll it will reach back over.
    ///
    /// Throws when there is no microphone to open - capture is not started, or the input
    /// device cannot feed the pipeline - so a press with nothing behind it is refused at
    /// the key rather than yielding an empty clip a transcriber would call a quiet room.
    /// [LAW:no-silent-failure]
    ///
    /// [LAW:one-source-of-truth] The moment is the one the event that began the session
    /// was stamped with, not the one this is called at, so a handler that ran late still
    /// marks the ring where the key went down. It names a position within this run of
    /// capture and nowhere else: a moment later than the newest sample marks the newest
    /// sample, since a session cannot begin in audio that has not been captured, and a
    /// moment earlier than the engine's first sample marks that first sample, since the
    /// audio before it is some earlier press's and belongs to no part of this one. Where
    /// the microphone opens for the session both clamps land on the same position, and the
    /// session begins where the microphone did; where the resting mode has held it open
    /// since `start()`, this run of capture reaches back that far and so may the pre-roll.
    ///
    /// What the forward clamp moves the mark past is not thrown away with it: the moment
    /// rides along on the session, and `endSession` reports the distance between them as
    /// the head the microphone was shut for. A key-down that reached here late addresses
    /// speech no engine can be started in time for, and a press that quietly began after
    /// the words it was pressed for is the one failure this whole path exists to refuse.
    /// [LAW:no-silent-failure]
    public func beginSession(at moment: HostTime, preRoll: TimeInterval = AudioSession.defaultPreRoll) throws -> AudioSession {
        guard case .started(var started) = phase else { throw NoMicrophone.stopped }
        guard !started.sessionIsOpen else {
            preconditionFailure("a session began while one was open; a press is one session")
        }
        // Cleared before any tap is installed, so the first buffer delivered after the key
        // is the one that dates this session's head. Cleared here and not in `launch()`
        // because a mid-session replacement launches too, and its first buffer dates its
        // own audio rather than the moment this session's microphone opened.
        shared.stream.withLock { $0.openedForSession = nil }
        switch started.engine {
        // Held open by the resting mode, and left alone: relaunching splices the ring, and
        // the audio it would splice off is exactly the look-back this mode is held open to
        // keep. The clearing above is right for a held microphone too, and dating the head
        // by the key instead would be wrong. Its buffers run continuously, so the first to
        // arrive after the key was captured at or before the key went down and the head
        // reads as heard; and a press a held engine delivers nothing for leaves this empty
        // and is reported unopened, exactly as a press whose own microphone never opened
        // is. Dating by the key would answer zero either way and take that door off a mode
        // that runs for hours. [LAW:no-silent-failure]
        case .running:
            break
        // Opened for this press.
        case .shut:
            do {
                started.engine = .running(try launch(on: started.prepared))
            } catch {
                // What failed may have been the device going away, and the input prepared
                // against it cannot open the one that replaced it. Readying another costs
                // no device and leaves the next press something that can open, where
                // keeping this one would refuse every press until capture is restarted.
                // The engine stays shut: recording a failure here is what the case below
                // exists not to do, because a failed engine left behind lets the next
                // device change hold open a microphone `shut` asked to keep closed.
                ready(&started)
                phase = .started(started)
                throw NoMicrophone.failed(error)
            }
        // A press is a reason to try the device again, and the alternative is a resting
        // microphone that stays dead until one is replugged. Recorded either way, which
        // `shut` above deliberately does not do: leaving a failed engine behind there
        // would let the next device change reach `recover()` with no session open and
        // hold the microphone a config asked to keep closed.
        case .failed(_, let since):
            do {
                // A retry after a failure readies the microphone again: what failed may
                // have been the device going away, and the input prepared against it
                // cannot open the one that replaced it.
                ready(&started)
                started.engine = .running(try launch(on: started.prepared))
                closeOutage(since: since)
            } catch {
                // The gap runs from where it began, carrying the newest reason: a retry
                // that failed again started no new gap, and the reason it is dead now is
                // the one the status surface has to show. [LAW:no-silent-failure]
                started.engine = .failed(error, since: since)
                phase = .started(started)
                throw NoMicrophone.failed(error)
            }
        }
        started.sessionIsOpen = true
        phase = .started(started)
        return shared.stream.withLock { stream in
            // One floor for the mark and for what the mark reaches back over: the
            // position this run of capture began at. [LAW:one-source-of-truth]
            let opened = stream.continuousSince
            return AudioSession(
                beginningAt: min(max(stream.timeline.position(at: moment), opened), stream.ring.end),
                at: moment,
                preRoll: preRoll,
                notReachingBefore: opened
            )
        }
    }

    /// Marks where `session` ends, yields its audio, and gives the microphone back to its
    /// resting state - which closes it unless the user asked for it to be held: the
    /// pre-roll, then everything captured since it began, and whether that is all of it.
    /// The end mark, the slice and what the slice is missing are taken under one lock, so
    /// a buffer arriving in between cannot separate them.
    ///
    /// [LAW:parse-dont-validate] This is the border a press's audio crosses, and it is
    /// the last place any of the losses can be seen: the ring clamps a range it cannot
    /// fill and hands back a shorter clip, a break between two engines leaves no mark in
    /// the samples at all, and a microphone that never opened leaves no samples to mark.
    /// So what crosses is a `CapturedAudio`, which cannot be read as whole unless it is.
    public func endSession(_ session: AudioSession) -> CapturedAudio {
        let open = isOpen
        let captured = shared.stream.withLock { stream -> CapturedAudio in
            let range = session.range(endingAt: stream.ring.end)
            // Where the session's own audio starts among the positions that exist: the
            // pre-roll may reach back before the first sample ever captured, and audio
            // that never existed was not lost.
            let began = range.clamped(to: 0..<stream.ring.end).lowerBound
            let clip = stream.ring.clip(in: range)
            // How long the session waited for its microphone, and a wait that never ended
            // for one nothing was ever delivered for - a hold shorter than the engine took
            // to start, or one whose engine never started. That is the same sentence about
            // the whole press that lateness is about its head, so it is the same reading
            // rather than one of its own. [LAW:one-source-of-truth]
            let openedLate = stream.openedForSession
                .map { session.unheard(since: $0) > .seconds(Self.warmUpAllowance) } ?? true
            let lost = CapturedAudio.Loss(
                scrolledOff: stream.ring.scrolledOff(from: range),
                interrupted: began < stream.continuousSince,
                // Two readings of one fact - the microphone was not open for part of this
                // session. It opened so long after the key went down that the stretch in
                // between is speech rather than warm-up, which takes the head; or it was
                // gone by the time the key came up and never came back, which takes the
                // tail.
                unopened: openedLate || !open
            )
            return lost.map { .partial(clip, lost: $0) } ?? .whole(clip)
        }
        rest()
        return captured
    }

    /// Holds the grant, watches the input device, and brings the microphone to its resting
    /// state. The grant is the proof the user allowed it: without one, macOS lets an engine
    /// run and hands it silence, which nothing downstream could tell from a quiet room.
    ///
    /// Under `shut`, which is what the app runs on when no config file asks for anything
    /// else, no engine launches here: the microphone opens when a session does, which is
    /// what keeps the menu-bar indicator a record of use rather than of uptime. Under
    /// `open` the engine launched here is the one every press speaks into, and an
    /// indicator lit for the life of the process is what the user asked for by writing it
    /// down. A launch that fails leaves capture started and failed rather than throwing:
    /// the device watch is up by then, so a microphone that appears later is picked up the
    /// same way one that disappears mid-press is.
    public func start(_ grant: MicrophoneGrant, atRest: MicrophoneAtRest) throws {
        stop()
        deviceChanges = 0
        outages = Outages()
        phase = .started(Started(
            watch: try hardware.watchDefaultInput { [weak self] in self?.recover() },
            grant: grant,
            atRest: atRest,
            engine: .shut,
            // Readied here rather than at the first press, which is the point: this is
            // the moment the app has time to spare, and a press is the moment it has
            // none. No device is opened by it, so a Mac nobody has dictated to still
            // shows no microphone.
            prepared: readiedInput()
        ))
        rest()
    }

    public func stop() {
        if case .started(let started) = phase {
            if case .running(let live) = started.engine { dispose(live) }
            started.watch()
        }
        phase = .stopped
    }

    // A non-Sendable @MainActor class is only ever held by main-actor code, so its
    // last release is on the main actor; assumeIsolated traps if that stops holding.
    deinit { MainActor.assumeIsolated { stop() } }

    private var isOpen: Bool {
        guard case .started(let started) = phase, case .running = started.engine else { return false }
        return true
    }

    /// Retires an engine: the stream stops accepting what it delivers, and then the tap
    /// comes down. Every path that lets an engine go comes through here, because one that
    /// retired an engine without telling the stream would leave a disposed tap a buffer's
    /// reach into the audio the next press begins from. [LAW:single-enforcer]
    ///
    /// [LAW:no-ambient-temporal-coupling] The order is the whole of it. Tearing the tap
    /// down first leaves a window in which a buffer already on its way can take the lock
    /// before the clearing does, read the generation it was formed for, and be admitted -
    /// so the guard would hold only as often as it won a race. Clearing first closes it
    /// from both sides: nothing sets `accepting` again until the next `launch()`, so a
    /// straggler is refused whether it arrives before `dispose()` returns or after.
    private func dispose(_ live: Live) {
        shared.stream.withLock { $0.accepting = nil }
        live.dispose()
    }

    /// Readies a microphone against whatever the default input is now, and spends any
    /// deferral that was waiting for one.
    ///
    /// [LAW:single-enforcer] Every way a prepared input is *replaced* comes through here,
    /// which is what keeps `readyAgainAtRest` from outliving the staleness it stands for.
    /// A press books the deferral and the bound device then dies before the key-up:
    /// `replaceEngine` readies another against the new default, so the booking is already
    /// paid, and a `rest()` that still saw it standing would tear down a microphone
    /// pointing at the right device to ready an identical one.
    private func ready(_ started: inout Started) {
        started.prepared = readiedInput()
        started.readyAgainAtRest = false
    }

    /// A microphone readied against whatever the default input is now, wired so that the
    /// device it ends up bound to going away or changing shape arrives at `inputWentStale`.
    ///
    /// [LAW:one-source-of-truth] The one place a preparation is wired, so the two moments one
    /// is made - starting capture, and replacing a stale one - cannot disagree about what
    /// watches it.
    private func readiedInput() -> any PreparedInput {
        preparations += 1
        let preparation = preparations
        return hardware.prepareInput { [weak self] in self?.inputWentStale(from: preparation) }
    }

    /// Lets the press go and brings the microphone to what it does while no session is
    /// open.
    ///
    /// [LAW:single-enforcer] The one place the resting mode is read. `start()` and the
    /// key-up that ends a press are the two moments no session is open, and both arrive
    /// here, so neither can leave the microphone in a state the other would not have left
    /// it in - which is what makes "the device is closed unless the file says otherwise" a
    /// property of one function rather than an agreement between two.
    private func rest() {
        guard case .started(var started) = phase else { return }
        started.sessionIsOpen = false
        // The default input changed under the press that just ended, and answering it was
        // put off to here rather than cutting the recording. Done before the resting mode
        // is read, so what the mode does next it does with the new device: `shut` holds a
        // microphone readied against it, and `open` launches on it rather than relaunching
        // on the one the press was holding.
        //
        // Only a running engine is given up. The press's engine can have died between the
        // booking and here, and that engine's outage is still open: taking it to `.shut`
        // would drop the reason and the moment it began, and `open` would relaunch over the
        // top of a gap nothing had booked. Readying is the half that is owed either way -
        // skip it for a failed engine and the next press opens the device that stopped
        // being the default, which is the whole of what this defers. [LAW:no-silent-failure]
        if started.readyAgainAtRest {
            if case .running(let live) = started.engine {
                dispose(live)
                started.engine = .shut
            }
            ready(&started)
        }
        switch started.atRest {
        case .shut:
            if case .running(let live) = started.engine { dispose(live) }
            started.engine = .shut
        case .open:
            switch started.engine {
            // Already open, and kept open across the key-up: the ring stays continuous, so
            // the next press's pre-roll has audio to reach back over. A failed one waits
            // on the device watch exactly as it does mid-press.
            case .running, .failed:
                break
            case .shut:
                do { started.engine = .running(try launch(on: started.prepared)) }
                catch { started.engine = .failed(error, since: .now) }
            }
        }
        phase = .started(started)
    }

    /// Books the end of a gap in capture. [LAW:single-enforcer] A device that came back is
    /// the same event whether the watch noticed it or a press did, so both arrive here and
    /// the count cannot depend on which of the two got there first.
    private func closeOutage(since: ContinuousClock.Instant) {
        outages.count += 1
        outages.total += .now - since
    }

    private func launch(on prepared: any PreparedInput) throws -> Live {
        let shared = shared
        generation += 1
        let generation = generation
        // Everything the engine about to launch captures lands from here on, and
        // everything already in the ring came from one that stopped. Marked before the
        // launch rather than after it: the new engine delivers on its own thread, and a
        // buffer that landed before the mark was taken would move the mark past audio
        // the break had already cost, so a session begun after the break would be told
        // it spanned one. [LAW:no-ambient-temporal-coupling]
        let resuming = shared.stream.withLock { stream -> Int in
            let previous = stream.continuousSince
            stream.continuousSince = stream.ring.end
            stream.accepting = generation
            return previous
        }
        do {
            let dispose = try prepared.open(
                appending: { samples, time in
                    shared.stream.withLock {
                        // Resolved by generation rather than trusted by arrival, as the
                        // other two callbacks already are: a buffer from an engine that has
                        // been disposed is a let-go press's audio, and the ring it would
                        // land in is where the next press begins.
                        guard $0.accepting == generation else { return }
                        // The buffer's first sample takes the position the ring is at, and
                        // that is the sample its stamp dates.
                        $0.timeline.mark($0.ring.end, at: time)
                        $0.openedForSession = $0.openedForSession ?? time
                        $0.ring.append(samples)
                    }
                },
                onFailure: { [weak self] error in self?.fail(error, from: generation) }
            )
            return Live(dispose: dispose, generation: generation)
        } catch {
            // Nothing took over, so nothing resumed: no tap was installed and no buffer
            // can have landed. A mark left standing forward of the last engine's audio
            // would tell the session that ends here it was spliced where capture in fact
            // simply stopped, which is a different sentence and a false one.
            // [FRAMING:representation]
            shared.stream.withLock { $0.continuousSince = resuming }
            throw error
        }
    }

    /// The device changed under a running engine: macOS already stopped it, and it never
    /// delivers again.
    ///
    /// Takes the engine to give up rather than a generation to find one by. Both callers have
    /// just matched one from the phase they are holding, and the callback that had to be
    /// resolved by generation - the engine's own configuration change - is the readied
    /// input's now and arrives at `inputWentStale`. [LAW:polishing-by-subtraction]
    private func replaceEngine(_ started: inout Started, _ live: Live) {
        dispose(live)
        do {
            // The device this was prepared against is not the one to open any more: it went
            // away, or it stopped being the default while nothing was recording it.
            ready(&started)
            started.engine = .running(try launch(on: started.prepared))
            deviceChanges += 1
        } catch {
            started.engine = .failed(error, since: .now)
        }
    }

    /// The device a readied microphone is bound to went away or changed shape. It can happen
    /// at any point in that microphone's life and not only while a press holds it open, which
    /// is the whole of why the watch behind this belongs to the input - see
    /// `AudioHardware.prepareInput`. Either way the input is no longer one to open, so both
    /// arms of this end in a fresh one.
    ///
    /// A running engine is replaced here and now, where `recover()` may leave a press
    /// recording: the device under that one is still the device it was opened on, and this is
    /// the case where it is not. macOS has already stopped the engine and it never delivers
    /// again, so a press left on it would record its remaining seconds into silence - a new
    /// engine on the device that replaced it salvages the rest of the utterance, and the
    /// splice is what the session reports. [LAW:no-silent-failure]
    ///
    /// A microphone that is merely readied has nothing to give up, so it is simply readied
    /// again - which opens no device, and is what closes the resting stretch this whole
    /// change is about.
    private func inputWentStale(from preparation: Int) {
        // Not the microphone a press would open any more, so nothing it says is about one.
        // A notification posted before its input was let go can arrive after, and acting on
        // it would give up an engine running healthily on the input that replaced it.
        guard case .started(var started) = phase, preparation == preparations else { return }
        switch started.engine {
        case .running(let live): replaceEngine(&started, live)
        // A failed engine is left failed: it is not this device's turn again until a press
        // or the default-input watch says so, and both ready a microphone of their own.
        case .shut, .failed: ready(&started)
        }
        phase = .started(started)
    }

    /// The default input device changed - which device a press should open, not anything
    /// about the one it is open on. That is the whole difference from `inputWentStale`: the
    /// bound device is still alive and still the shape it was, so a press on it is left
    /// recording and only the *next* one owes anything. A failed engine has no device to
    /// stay on, so this is also how one reaches a device that appeared; a launch that fails
    /// again (the device that appeared cannot feed the pipeline either) extends the same
    /// outage.
    ///
    /// A shut microphone is not woken by this. Nobody is holding the key, so nobody is
    /// dictating, and a device appearing is not a reason to start listening to it. What a
    /// shut microphone does do is ready itself against the device that is now the default:
    /// preparing opens nothing and lights no indicator, and skipping it left the next press
    /// launching on an input bound to a device that had stopped being the default - which a
    /// press has no way to notice and no way to recover from, because the `shut` branch of
    /// `beginSession` deliberately records no failure.
    private func recover() {
        guard case .started(var started) = phase else { return }
        switch started.engine {
        // A running engine owns the input it was launched on: the disposal it holds is weak,
        // so `prepared` is the only strong reference to the open input and replacing it under
        // a live press would deinit the device out from under it. That is also the right
        // answer on its own terms - a switch of the default input is not a reason to cut the
        // recording the speaker is in the middle of making - but forgetting it happened is
        // not, so the work is booked for `rest()`, the moment "no session is open" becomes
        // true, and done there.
        case .running where started.sessionIsOpen:
            started.readyAgainAtRest = true
        // With no session open there is nothing to cut, and the engine is replaced on the new
        // default the same way a device that went away replaces it.
        case .running(let live):
            replaceEngine(&started, live)
        case .shut:
            ready(&started)
        case .failed(_, let since):
            do {
                ready(&started)
                started.engine = .running(try launch(on: started.prepared))
                closeOutage(since: since)
            } catch {
                started.engine = .failed(error, since: since)
            }
        }
        phase = .started(started)
    }

    /// A failure from an engine a device change has since replaced is stale: the
    /// engine it came from is gone and the one running is healthy.
    ///
    /// [LAW:no-ambient-temporal-coupling] The tap's failure arrives asynchronously, so the
    /// engine it is about is resolved by generation rather than trusted by arrival - a
    /// replaced engine's late failure would otherwise fail the one that took over from it.
    private func fail(_ error: any Error, from generation: Int) {
        guard case .started(var started) = phase,
              case .running(let live) = started.engine,
              live.generation == generation else { return }
        dispose(live)
        started.engine = .failed(error, since: .now)
        phase = .started(started)
    }
}

/// A press with no microphone behind it, refused at the key rather than heard.
public enum NoMicrophone: Error, CustomStringConvertible {
    /// Capture was never started, or has been stopped.
    case stopped
    /// The microphone could not be opened for this session.
    case failed(any Error)

    public var description: String {
        switch self {
        case .stopped: "the microphone is not being captured; nothing was heard"
        case .failed(let error): "the microphone could not be opened: \(error); nothing was heard"
        }
    }
}
