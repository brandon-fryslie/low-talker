import Foundation
import Synchronization

/// Microphone capture whose engine lives for one session. `start` holds the grant and
/// watches the input device; it opens nothing, so a Mac with low-talker running and
/// nobody dictating shows no microphone in the menu bar. `beginSession` opens the
/// microphone, `endSession` closes it, and between the two the ring fills as before: a
/// session is still two positions on the ring.
///
/// What that costs is the look-back. A session's pre-roll reaches back over audio the
/// microphone was already capturing, and an engine opened at key-down has none behind
/// it, so the pre-roll clamps to nothing and the utterance starts where the microphone
/// did. Measured on this Mac's built-in input, `AVAudioEngine.start()` returns 39 ms
/// after it is called and the first sample it captures was taken 37 ms after
/// (±1 ms over launches spaced 0 to 3 s apart; without `prepare()` first, 65 ms; the
/// first launch in a process costs 240-280 ms and only an engine that actually ran the
/// device pays that down, which is why it is not paid at launch). 37 ms is shorter than
/// the gap between deciding to press a key and beginning to say a word, so a press
/// followed by speech loses nothing; a press made *during* a word loses the part of it
/// that was said before the key went down, and no engine can be started in the past.
///
/// That argument covers the warm engine and nothing else, so the gap is measured rather
/// than assumed: `endSession` reads the stretch between the key going down and the first
/// sample anything captured, and a press missing more of it than `warmUpAllowance` comes
/// back partial instead of whole. Two things reach that door - the first press in a
/// process, which pays the cold 244 ms, and a key-down the tap delivered late, which pays
/// whatever was ahead of it. Both are speech the speaker addressed to a shut microphone,
/// and a press that says so is one they can repeat; a sentence quietly missing its front
/// is not. [LAW:no-silent-failure]
///
/// The engine is disposable and the ring is not. When the input device changes, macOS
/// stops the engine and posts a configuration change, and a tap reinstalled on that
/// engine never delivers another buffer (tried with stop, reset, prepare, and a delay);
/// only a fresh engine on the new device does. So a device change launches a new engine
/// by the same routine as opening one, and the ring, which lives here rather than in any
/// engine, carries across. What it carries across is spliced: no audio is captured
/// between the two engines, so the position the new one resumes at is kept and a session
/// that spans it is told its clip is not whole.
///
/// When the only input device is unplugged mid-session, the replacement cannot launch
/// (there is nothing to convert from) and capture is failed. A failed capture has no
/// engine, so the plug-back-in reaches it another way: the system default input device
/// is watched for the whole started period, and a change while failed launches again.
/// A change while no session is open launches nothing at all - that is the whole point
/// of the watch outliving the engine without implying one.
@MainActor
public final class AudioCapture {
    public enum State {
        case stopped
        /// Started, with no session open: the grant is held and the input device is
        /// watched, and the microphone is shut.
        case listening
        /// A session is open, so the microphone is too.
        case running
        /// The session's engine stopped on its own. It stays that way until the default
        /// input device changes, when it launches again, or until the session ends.
        case failed(any Error)
    }

    /// The gaps in capture since `start()`, each ended by a device appearing: how
    /// many, and how long without audio all together.
    public struct Outages: Sendable {
        public var count = 0
        public var total: Duration = .zero
    }

    /// An engine on the input device of its moment. The generation is what this
    /// engine's callbacks carry (the tap's failure, the observer's change), so a
    /// callback from a replaced engine is recognized as stale (a counter, because a
    /// replaced engine's address can be reused).
    private struct Live {
        let dispose: Disposal
        let generation: Int
    }

    /// What the microphone is doing, which is what the session it belongs to is doing.
    private enum Engine {
        /// No session is open, so nothing is running and macOS shows nothing.
        case shut
        case running(Live)
        /// The open session's engine has been gone since `since`.
        case failed(any Error, since: ContinuousClock.Instant)
    }

    /// [LAW:types-are-the-program] The grant and the default-input watch exist exactly
    /// between `start()` and `stop()`, whatever the microphone is doing, so they live
    /// beside the engine rather than in optionals every reader would have to reconcile.
    private struct Started {
        let watch: Disposal
        let grant: MicrophoneGrant
        var engine: Engine
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
        /// buffers must not re-date it. Empty means nothing has been delivered since the
        /// session began, which is a microphone that never opened for it at all.
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
    /// Input device changes an open session's capture stayed running across since
    /// `start()`: the engine was replaced without ever failing. Not a claim that no audio
    /// was lost to them - the audio on either side of each one is spliced, which is what
    /// a session's `CapturedAudio` says and this count does not.
    public private(set) var deviceChanges = 0
    public private(set) var outages = Outages()

    nonisolated public static let defaultRetention: TimeInterval = 60

    /// How long the microphone may take to open after the key went down before the press
    /// is treated as having missed speech rather than as having warmed up.
    ///
    /// This is the number the epic traded the look-back for, so it is written down rather
    /// than tuned. Measured on this Mac's built-in input, an engine that has run the
    /// device before captures its first sample 37 ms after `start()` is called, ±1 ms
    /// over launches spaced 0 to 3 s apart. The allowance is 100 ms: near three times
    /// that, and an order of magnitude under the two ways a microphone actually opens
    /// late - the first launch in a process, which costs 240-280 ms because only an
    /// engine that has run the device pays that down, and a key-down the tap delivered
    /// late, which costs whatever the handler ahead of it was doing (the epic measured a
    /// 43-character insert at about 1.2 s). Ordinary presses and missed speech are two
    /// populations that far apart, so the allowance never has to be retuned to keep an
    /// ordinary press whole. [LAW:no-silent-failure]
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
            case .shut: .listening
            case .running: .running
            case .failed(let error, _): .failed(error)
            }
        }
    }

    /// Opens the microphone and marks where the session begins: the position capture had
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
    /// audio before it is some earlier press's and belongs to no part of this one. With
    /// the microphone opening for the session both clamps land on the same position, and
    /// the session begins where the microphone did.
    ///
    /// What the forward clamp moves the mark past is not thrown away with it: the moment
    /// rides along on the session, and `endSession` reports the distance between them as
    /// the head the microphone was shut for. A key-down that reached here late addresses
    /// speech no engine can be started in time for, and a press that quietly began after
    /// the words it was pressed for is the one failure this whole path exists to refuse.
    /// [LAW:no-silent-failure]
    public func beginSession(at moment: HostTime, preRoll: TimeInterval = AudioSession.defaultPreRoll) throws -> AudioSession {
        guard case .started(var started) = phase else { throw NoMicrophone.stopped }
        guard case .shut = started.engine else {
            preconditionFailure("a session began while one was open; the microphone's lifetime is one session's")
        }
        // Cleared before the tap is installed, so the first buffer this session's
        // microphone delivers is the one that dates its head. Cleared here and not in
        // `launch()` because a mid-session replacement launches too, and its first buffer
        // dates its own audio rather than the moment this session's microphone opened.
        shared.stream.withLock { $0.openedForSession = nil }
        do {
            started.engine = .running(try launch())
        } catch {
            throw NoMicrophone.failed(error)
        }
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

    /// Marks where `session` ends, yields its audio, and closes the microphone: the
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
        shut()
        return captured
    }

    /// Holds the grant and watches the input device. The grant is the proof the user
    /// allowed it: without one, macOS lets an engine run and hands it silence, which
    /// nothing downstream could tell from a quiet room.
    ///
    /// No engine launches here. The microphone opens when a session does, which is what
    /// keeps the menu-bar indicator a record of use rather than of uptime.
    public func start(_ grant: MicrophoneGrant) throws {
        stop()
        deviceChanges = 0
        outages = Outages()
        phase = .started(Started(watch: try hardware.watchDefaultInput { [weak self] in self?.recover() }, grant: grant, engine: .shut))
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

    /// Retires an engine: the tap comes down, and the stream stops accepting what it
    /// delivers. Every path that lets an engine go comes through here, because one that
    /// retired an engine without telling the stream would leave a disposed tap a buffer's
    /// reach into the audio the next press begins from. [LAW:single-enforcer]
    private func dispose(_ live: Live) {
        live.dispose()
        shared.stream.withLock { $0.accepting = nil }
    }

    /// Closes the microphone, whatever the open session's engine was doing.
    private func shut() {
        guard case .started(var started) = phase else { return }
        if case .running(let live) = started.engine { live.dispose() }
        started.engine = .shut
        phase = .started(started)
    }

    /// The running engine, only while it is still the one a callback was formed for.
    /// [LAW:no-ambient-temporal-coupling] An observer block already queued when
    /// `dispose()` removes the observer still runs, and the tap's failure arrives
    /// asynchronously, so both callbacks are resolved here by generation rather than
    /// trusted by arrival - and a session that has since ended matches nothing, so a
    /// callback cannot reopen a microphone the speaker let go of.
    private func live(of generation: Int) -> (started: Started, live: Live)? {
        guard case .started(let started) = phase, case .running(let live) = started.engine, live.generation == generation else { return nil }
        return (started, live)
    }

    private func launch() throws -> Live {
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
            let dispose = try hardware.launch(
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
                onFailure: { [weak self] error in self?.fail(error, from: generation) },
                onConfigurationChange: { [weak self] in self?.replaceEngine(from: generation) }
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

    /// The device changed under an open session: macOS already stopped the engine, and
    /// it never delivers again.
    private func replaceEngine(from generation: Int) {
        guard let running = live(of: generation) else { return }
        dispose(running.live)
        var started = running.started
        do {
            started.engine = .running(try launch())
            deviceChanges += 1
        } catch {
            started.engine = .failed(error, since: .now)
        }
        phase = .started(started)
    }

    /// The default input device changed. An open session's running engine hears that
    /// itself, through its configuration change; a failed one has no engine to hear
    /// with, so this is how a device that appears reaches it. A launch that fails again
    /// (the device that appeared cannot feed the pipeline either) extends the same
    /// outage.
    ///
    /// A shut microphone is not woken by this. Nobody is holding the key, so nobody is
    /// dictating, and a device appearing is not a reason to start listening to it.
    private func recover() {
        guard case .started(var started) = phase, case .failed(_, let since) = started.engine else { return }
        do {
            started.engine = .running(try launch())
            outages.count += 1
            outages.total += .now - since
        } catch {
            started.engine = .failed(error, since: since)
        }
        phase = .started(started)
    }

    /// A failure from an engine a device change has since replaced is stale: the
    /// engine it came from is gone and the one running is healthy.
    private func fail(_ error: any Error, from generation: Int) {
        guard let running = live(of: generation) else { return }
        dispose(running.live)
        var started = running.started
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
