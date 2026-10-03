import LowTalkerCore
import Synchronization

/// The loop from a press of the hotkey to words at the cursor: key-down names the app in
/// front and opens the microphone, marking where the utterance begins on the ring, and the
/// engine starts hearing it as it is captured, committing words at the cursor as they are
/// confirmed; key-up ends it and closes the microphone again; and the rest of the transcript
/// is routed and inserted while the next press can already begin.
///
/// [LAW:decomposition] Presses in, sessions out. The microphone, the engine, the
/// router and the input method are values it is given, so the whole loop runs in a test
/// against a fake of each and the app's delegate only hands over the real ones. The
/// hotkey is not among them: it is fed `press`, and what starts it is not this loop's
/// concern. [LAW:composability]
///
/// [LAW:no-ambient-temporal-coupling] The engine hears each press after the press before
/// it, and each press's commits and its session are inserted on one serial queue, so two
/// presses in quick succession insert in the order they were spoken and never interleave,
/// however long the engine takes on either. Key-down and key-up reach this from the main queue, as the hotkey
/// hands them on.
///
/// With the microphone shut at rest, audio before the engine launches does not exist, so
/// a later launch is a longer head the microphone was not open for, and `beginSession`
/// reports that head. Held open at rest there is nothing to launch and the press is a mark
/// on a ring that is already turning. A press carries the moment its key went down and the
/// ring is read from there, so nothing already recorded is lost by arriving late. Sessions
/// are inserted on this same actor, so the insert awaits the input method's answer rather
/// than holding the actor for it: a press made in the middle of an insert is marked on the
/// ring when it is made.
@MainActor
public final class Dictation {
    /// One press the speaker ended, done: where it went, what was heard, how long after
    /// key-up, and what was inserted. An utterance with nothing said in it is a session
    /// that performed nothing, not a failure.
    ///
    /// [LAW:types-are-the-program] A press the hotkey stopped during never reaches one of
    /// these, and neither does one whose audio the ring could not hand over whole; those
    /// are reported as `PressLapsed` and `SpeechLost`. What is left is the press this
    /// type says it is: one the speaker ended, heard from every sample it covered.
    public struct Session: Sendable, CustomStringConvertible {
        public let context: Context
        public let transcript: Transcript
        /// What the engine had shown by the time the key came up.
        public let duringPress: DuringPress
        /// From the key coming up to the transcript, the engine's share of the wait.
        public let keyUpToTranscript: Duration
        /// What the press's hold put off of the engine's served callers.
        public let displaced: EngineHold.Displaced
        public let performed: [Executor.Performed]

        /// The session in numbers, without the words: they are what the user
        /// dictated, and each surface decides for itself whether to show them.
        /// [LAW:one-source-of-truth] The app's log line and the CLI's are this, and
        /// where the words went is read off what was performed rather than off the app
        /// that happened to be in front at key-down: an insert is answered by the app whose
        /// cursor took the words, which the person may have moved to while they were still
        /// speaking. Each action already carries the app it is about, so this line and the
        /// action lines under it cannot name different apps for one insert.
        public var description: String {
            let into = Set(performed.map(\.into)).map(\.rawValue).sorted().joined(separator: ", ")
            let destination = into.isEmpty ? "" : " into \(into)"
            return "heard \(transcript.words.count) words past \(String(format: "%.1f", transcript.quiet)) s of quiet \(Int(keyUpToTranscript / .milliseconds(1))) ms after key-up (\(duringPress); \(displaced)), \(performed.count) actions\(destination)"
        }
    }

    /// What a press showed while the key was still down: the passes its decode had run, how
    /// long after the key went down the first of them read any words, and the confirmed
    /// words already committed at the cursor.
    public struct DuringPress: Sendable, CustomStringConvertible {
        public let passes: Int
        /// [LAW:types-are-the-program] Absent when no pass before key-up read a word,
        /// which a short tap or a slow engine leaves - not a zero, which would say the
        /// words were there at once.
        public let firstWords: Duration?
        /// The inserts acknowledged before key-up, and the words they carried.
        public let commits: Int
        public let wordsCommitted: Int
        /// Absent when nothing was committed before key-up, for the reason `firstWords` is.
        public let firstCommit: Duration?

        public var description: String {
            let words = firstWords.map { "first words \(Int($0 / .milliseconds(1))) ms after key-down" } ?? "no words before key-up"
            let committed = firstCommit.map { "\(commits) commits of \(wordsCommitted) words, the first \(Int($0 / .milliseconds(1))) ms after key-down" } ?? "nothing committed before key-up"
            return "\(passes) passes during the press, \(words), \(committed)"
        }
    }

    /// One press as its decode unfolds: the partials counted as they come, the confirmed
    /// words handed out as runs to commit while the press is open, and what landed.
    ///
    /// What the press showed is read once, at key-up: a pass or a commit that ends after it
    /// changes nothing that is read again.
    ///
    /// [LAW:types-are-the-program] A press whose mode waits for the whole transcript is one
    /// that is stopped from the start: its runs are empty, so it commits nothing, by the same
    /// path every press takes. [LAW:dataflow-not-control-flow]
    private final class Streaming: Sendable {
        /// The confirmed words not yet handed out, made into what the mode makes of them.
        struct Run {
            let actions: [Action]
            let words: Int
            let since: Executor.Since
        }

        /// What the press is heard through once its microphone is open: the decode, and the
        /// capture's reading of what the press's audio already lacks.
        struct Hearing {
            let decode: Task<Decoded, Never>
            let missing: @MainActor @Sendable () -> CapturedAudio.Loss?
        }

        private struct State {
            var passes = 0
            var firstWords: Duration?
            /// Nil while the key is down.
            var keyUp: ContinuousClock.Instant?
            var confirmed: [Transcript.Word] = []
            var cursor = ConfirmedCursor()
            /// Nil once the press stops committing.
            var asHeard: (@Sendable (Transcript) -> Action?)?
            /// Nil until the microphone is open, and for a press refused before it was.
            var hearing: Hearing?
            var performed: [Executor.Performed] = []
            var words = 0
        }

        /// [LAW:one-source-of-truth] The key event's own stamp, on the clock every insert is
        /// timed by: a key-down told late is timed from where the key went down, by every
        /// line that times from it.
        private let keyDown: ContinuousClock.Instant
        private let state: Mutex<State>
        private let wake: AsyncStream<Void>.Continuation
        /// A wake for each change to the confirmed words; ends when no more can come. The
        /// newest is all that is kept, since each run takes every word confirmed so far.
        let wakes: AsyncStream<Void>

        init(since keyDown: HostTime, committing asHeard: (@Sendable (Transcript) -> Action?)?) {
            self.keyDown = .now - (HostTime.now - keyDown)
            state = Mutex(State(asHeard: asHeard))
            (wakes, wake) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        }

        /// The microphone is open and the decode begun.
        func hearing(_ decode: Task<Decoded, Never>, missing: @escaping @MainActor @Sendable () -> CapturedAudio.Loss?) {
            state.withLock { $0.hearing = Hearing(decode: decode, missing: missing) }
        }

        func heard(_ partial: Partial) {
            let now = ContinuousClock.now
            state.withLock { state in
                state.passes += 1
                state.firstWords = state.firstWords ?? (partial.text.isEmpty ? nil : now - keyDown)
                state.confirmed = partial.confirmed.words
            }
            wake.yield()
        }

        /// The decode is over: nothing more is confirmed. What the transcript adds past the
        /// confirmed words is `rest`'s.
        func decoded() {
            wake.finish()
        }

        /// The words confirmed since the last run, which are now this run's.
        ///
        /// While the key is down, audio the capture already knows is missing stops the
        /// commits: what is confirmed from then on reads a fragment, and key-up reports the
        /// loss with the words that landed before it. From key-up on, how the press ended
        /// says. [LAW:no-silent-failure]
        @MainActor func take() -> Run {
            if let missing = state.withLock({ $0.keyUp == nil ? $0.hearing?.missing : nil }), missing() != nil { stop() }
            return state.withLock { state in
                let since: Executor.Since = state.keyUp.map { .keyUp($0) } ?? .keyDown(keyDown)
                guard let asHeard = state.asHeard else { return Run(actions: [], words: 0, since: since) }
                let run = state.cursor.advance(through: state.confirmed)
                return Run(actions: asHeard(run).map { [$0] } ?? [], words: run.words.count, since: since)
            }
        }

        /// What the transcript holds past every word already handed out as a run: all of it
        /// for a mode that waits for the whole transcript.
        func rest(of transcript: Transcript) -> Transcript {
            state.withLock { $0.cursor.advance(through: transcript.words) }
        }

        /// A run landed at the cursor.
        func landed(_ run: Run, as performed: [Executor.Performed]) {
            state.withLock { state in
                state.performed += performed
                state.words += run.words
            }
        }

        /// The inserts that landed, and the words they carried.
        var landed: (performed: [Executor.Performed], words: Int) {
            state.withLock { ($0.performed, $0.words) }
        }

        /// Nothing more is committed for this press, whatever is confirmed after this, and its
        /// decode, which no one will read, stops: the engine goes back to whoever is waiting.
        func stop() {
            let decode = state.withLock { state in
                state.asHeard = nil
                return state.hearing?.decode
            }
            decode?.cancel()
            wake.finish()
        }

        /// The key came up: what the press showed while it was open.
        func keyUp(at instant: ContinuousClock.Instant) -> DuringPress {
            state.withLock { state in
                state.keyUp = instant
                return DuringPress(passes: state.passes, firstWords: state.firstWords, commits: state.performed.count, wordsCommitted: state.words, firstCommit: state.performed.first?.acknowledged)
            }
        }
    }

    /// A press's decode, begun at key-down: the transcript it came to, when, and what the
    /// press's hold put off. The hold is let go inside it the moment the transcript is out,
    /// so served callers wait for this press's engine and not for an earlier press's insert.
    private struct Decoded: Sendable {
        let transcript: Result<Transcript, any Error>
        let at: ContinuousClock.Instant
        let displaced: EngineHold.Displaced
    }

    /// What key-down left for key-up: the marks on the ring, the app in front, the decode
    /// already hearing the press and the commits already queued behind it, or the reason
    /// there was nothing to insert into. [LAW:types-are-the-program] One value rather than
    /// an optional session beside an optional app, so an end can never find half a beginning.
    private enum Press {
        case up
        case down(Open)
        case refused(any Error)
    }

    private struct Open {
        let session: AudioCapture.StreamedSession
        let into: BundleID
        let decode: Task<Decoded, Never>
        let streaming: Streaming
        /// What stopped the commits, when something did.
        let committing: Task<(any Error)?, any Error>
    }

    /// How a press that was heard ended.
    private enum Ending: Sendable {
        case released(Context)
        case lapsed(KeyChord)
        case lost(KeyChord, CapturedAudio.Loss)
    }

    /// A press that was heard, handed to the queue: how it ended, what it showed while it was
    /// open, its commits, and the decode that will say what was in it.
    private struct Heard: Sendable {
        let ending: Ending
        let duringPress: DuringPress
        let decode: Task<Decoded, Never>
        let streaming: Streaming
        let committing: Task<(any Error)?, any Error>
    }

    private let capture: AudioCapture
    private let transcriber: @Sendable @MainActor () async throws -> any Transcriber
    private let turns: EngineTurns
    private let router: Router
    private let executor: Executor
    private let frontmost: @Sendable @MainActor () throws -> BundleID
    private let report: @Sendable @MainActor (Result<Session, any Error>) -> Void
    private var press: Press = .up
    /// The decode of the latest press, which the next press's decode waits out before it
    /// takes the engine. Nil until the first press.
    private var latestDecode: Task<Decoded, Never>?
    private let sessions = SerialQueue()

    /// `transcriber` is awaited per session, so a press that comes while the model is
    /// still loading waits for it and inserts when it lands: loading is not a state
    /// this loop has. `turns` is the engine's owner, which every press holds from key-down
    /// until its transcript is out, so served callers wait for the speaker rather than the
    /// speaker for them. [LAW:dataflow-not-control-flow] `report` hears every session's
    /// outcome on the main actor, in the order the presses came.
    public init(
        capture: AudioCapture,
        transcriber: @escaping @Sendable @MainActor () async throws -> any Transcriber,
        turns: EngineTurns,
        router: Router,
        executor: Executor,
        frontmost: @escaping @Sendable @MainActor () throws -> BundleID = TargetApp.frontmost,
        report: @escaping @Sendable @MainActor (Result<Session, any Error>) -> Void
    ) {
        self.capture = capture
        self.transcriber = transcriber
        self.turns = turns
        self.router = router
        self.executor = executor
        self.frontmost = frontmost
        self.report = report
    }

    /// The hotkey's handler. The detector pairs every `began` with one `ended`, a lapse
    /// included, and this loop counts on that pairing rather than repairing it: a
    /// press out of order is a broken detector, not a session.
    public func press(_ transition: HotkeyDetector.Transition) {
        switch transition {
        case .began(_, let moment):
            guard case .up = press else { preconditionFailure("a press began while one was open; the detector pairs every began with an ended") }
            // First, so a served decode in flight is cancelled before the microphone opens,
            // and taken by every press, refused or not: a refused press lets go of it at once,
            // and a heard one when its decode stops. [LAW:dataflow-not-control-flow]
            let hold = turns.hold()
            let streaming = Streaming(since: moment, committing: router.asHeard)
            do {
                // The app in front before the microphone, so a reading that throws cannot
                // leave a microphone open with no session to close it; it is one read of
                // the workspace, which the engine's start dwarfs. [LAW:no-ambient-temporal-coupling]
                let into = try frontmost()
                // Queued before the microphone opens, so the one failure left after it is
                // none: the commits take their turn behind every session before this press,
                // and the session after it takes its turn behind them.
                let committing = try sessions.submit { try await self.commit(streaming) }
                // The mark comes from the event's own stamp, so a key-down told late
                // marks the ring where the key went down. What it reaches
                // back over is the resting mode's to say: nothing behind a microphone that
                // opens here, and the look-back behind one held open since `start()`.
                let session = capture.stream(try capture.beginSession(at: moment))
                let decode = decode(session.audio, into: streaming, releasing: hold)
                streaming.hearing(decode) { [capture] in capture.missing(from: session) }
                press = .down(Open(session: session, into: into, decode: decode, streaming: streaming, committing: committing))
            } catch {
                // Nothing will be decoded, so the commits queued for it end at once.
                streaming.stop()
                hold.release()
                press = .refused(error)
            }
        case .ended(let chord, let ending):
            let keyUp = ContinuousClock.now
            let open = press
            press = .up
            // What there is to hear, or the reason there is nothing. One value, so a
            // press that was refused at key-down and one that was heard leave here by
            // the same path: the failure is thrown inside the queued operation, which
            // is what makes it wait its turn instead of overtaking a session still
            // being inserted. [LAW:dataflow-not-control-flow]
            let heard: Result<Heard, any Error>
            switch open {
            case .up:
                preconditionFailure("a press ended that never began; the detector pairs every ended with a began")
            case .refused(let error):
                heard = .failure(error)
            case .down(let down):
                // Read before the session ends, so it holds only what the press showed
                // while it was open.
                let duringPress = down.streaming.keyUp(at: keyUp)
                // The marks are closed and the microphone with them, however the press
                // ended, so a session left open cannot carry its beginning into the next
                // press's clip and cannot leave the device held after the key came up.
                // Its audio ends here too, which is what lets the decode finish.
                let lost = capture.endSession(down.session)
                // How the press ended, read once. [LAW:no-silent-failure] A hotkey that
                // stopped and audio the capture could not stream whole each leave
                // something this loop must not report as an utterance. The lapse is asked
                // first: a press the hotkey stopped during says so rather than describing the
                // clip it left behind, which was never the whole utterance anyway. A
                // microphone that was not there at all was refused at key-down, so it
                // never reaches here. The focused element's role is a synchronous call
                // into another process, up to half a second of it, and this is the main
                // actor: a press waits on it, and so does every window this app draws.
                // A route that wants the role reads it off this thread.
                let ended: Ending = switch (ending, lost) {
                case (.lapsed, _): .lapsed(chord)
                case (.released(let kind), nil): .released(Context(chord: chord, press: kind, frontmostApp: down.into, focusedElementRole: nil))
                case (.released, let lost?): .lost(chord, lost)
                }
                // A press that will not be inserted commits nothing more and has no use for
                // the rest of its decode. What it already committed stays: the person watched
                // it arrive. Stopped here on the main actor, where every run is taken, so a
                // pass the ended audio lets the engine finish is never committed.
                switch ended {
                case .released: break
                case .lapsed, .lost: down.streaming.stop()
                }
                heard = .success(Heard(ending: ended, duringPress: duringPress, decode: down.decode, streaming: down.streaming, committing: down.committing))
            }
            do {
                // Handed over before key-up returns, so a `finish` that comes next
                // cannot miss this press. Reported from inside the operation, so the
                // queue that orders the inserts orders the telling of it too, and a
                // drain that waited for the one has waited for the other.
                // [LAW:no-ambient-temporal-coupling] [LAW:single-enforcer]
                try sessions.submit { [report] in
                    let outcome: Result<Session, any Error>
                    do {
                        outcome = .success(try await self.hear(heard, since: keyUp))
                    } catch {
                        outcome = .failure(error)
                    }
                    await report(outcome)
                }
            } catch {
                // The operation reports its own outcome; only the queue's own refusal
                // to accept it reaches here, and then nothing will ever read the decode, so
                // it is stopped and lets go of the engine as it does. [LAW:no-silent-failure]
                if case .success(let heard) = heard { heard.decode.cancel() }
                report(.failure(error))
            }
        }
    }

    /// Returns once every session already begun has been inserted and reported.
    ///
    /// [LAW:no-ambient-temporal-coupling] A process that exits while a session is in flight
    /// loses words the speaker has already said. This is what a surface awaits before it
    /// goes, and the wait is on the sessions themselves rather than on a grace period long
    /// enough to probably cover them.
    public func finish() async throws {
        try await sessions.drain()
    }

    /// Hears the press while it is still going on: the session's audio is handed to the
    /// engine as it is captured, each pass is shown to `streaming`, and the transcript is
    /// what the engine makes of it once the key comes up and the audio ends.
    /// [LAW:one-type-per-behavior] A held press and a toggled one are heard the same way;
    /// how the press was made is the context's to say.
    ///
    /// [LAW:no-ambient-temporal-coupling] It takes the engine once the press before it has
    /// its transcript, so a press made while the last one's final pass is still to run
    /// cannot put its own passes ahead of it; its audio waits on the stream meanwhile.
    ///
    /// The hold ends with the transcript, whatever became of it: the insert that follows is
    /// not the engine's, and served callers wait for this press and no longer.
    private func decode(_ audio: AsyncStream<AudioClip>, into streaming: Streaming, releasing hold: EngineHold) -> Task<Decoded, Never> {
        let before = latestDecode
        let decode = Task { [transcriber] in
            _ = await before?.value
            let transcript: Result<Transcript, any Error>
            do {
                transcript = .success(try await transcriber().transcribe(audio, expecting: .empty) { streaming.heard($0) })
            } catch {
                transcript = .failure(error)
            }
            streaming.decoded()
            return Decoded(transcript: transcript, at: .now, displaced: hold.release())
        }
        latestDecode = decode
        return decode
    }

    /// Commits a press's confirmed words as they come, each run as one insert, until its
    /// decode is over or the press stops committing. Runs in the press's turn on the
    /// queue, so the words land after every press before it and before every press after it.
    ///
    /// [LAW:no-silent-failure] An insert that fails stops the commits for the rest of the
    /// press, and is what this returns: the words after it go nowhere else.
    private func commit(_ streaming: Streaming) async -> (any Error)? {
        for await _ in streaming.wakes {
            let run = streaming.take()
            do {
                streaming.landed(run, as: try await executor.perform(run.actions, following: streaming.landed.performed, since: run.since))
            } catch {
                streaming.stop()
                // A run is one insert, so none of it was done, and what stopped it is the cause.
                return (error as? RouteStopped)?.cause ?? error
            }
        }
        return nil
    }

    /// Waits for the press's commits and its decode, then routes and inserts what was heard
    /// and not yet committed. A press that will not be inserted is reported in its turn
    /// without waiting on its decode, which was told to stop and may still be waiting for
    /// the model to load.
    private func hear(_ heard: Result<Heard, any Error>, since keyUp: ContinuousClock.Instant) async throws -> Session {
        let heard = try heard.get()
        let stopped = try await heard.committing.value
        let landed = heard.streaming.landed
        // [LAW:no-silent-failure] The report names what stopped the press's words first: a
        // refused commit came before whatever the key-up found.
        if let stopped { throw PressStopped(landed: landed.words, cause: stopped) }
        let context: Context
        switch heard.ending {
        case .released(let released): context = released
        case .lapsed(let chord): throw PressLapsed(chord: chord, landed: landed.words)
        case .lost(let chord, let lost): throw SpeechLost(chord: chord, lost: lost, landed: landed.words)
        }
        do {
            let decoded = await heard.decode.value
            let transcript = try decoded.transcript.get()
            let performed = try await executor.perform(router.actions(for: heard.streaming.rest(of: transcript), in: context), following: landed.performed, since: .keyUp(keyUp))
            return Session(context: context, transcript: transcript, duringPress: heard.duringPress, keyUpToTranscript: decoded.at - keyUp, displaced: decoded.displaced, performed: landed.performed + performed)
        } catch {
            // [LAW:no-silent-failure] Whatever stopped the press, the report says how many of
            // its words are already at the cursor.
            throw PressStopped(landed: landed.words, cause: error)
        }
    }
}

/// A press the hotkey stopped hearing partway through, reported instead of inserted.
///
/// The hotkey stopped while the key was down - the app rebuilding its loop, or quitting -
/// so what was captured runs from the press to the stop rather than to the release, and
/// whether the speaker had even finished is unknown.
///
/// [LAW:no-silent-failure] Nothing more is inserted once it stops. Half a sentence inserted
/// at the end arrives unmarked as half, and it cannot be marked: the destination is the
/// user's editor, not this app's, and once the words are in it nothing here can say which
/// ones were missing. Words committed while the press was open stay, and this says how
/// many: the person watched them arrive, so they are not unmarked. A press that says it
/// was cut off is a thing they can act on by saying the rest again.
public struct PressLapsed: WordFree {
    /// The chord that was down when the hotkey stopped.
    public let chord: KeyChord
    /// The words committed before it stopped.
    public let landed: Int

    public var description: String { "WARNING: The hotkey stopped listening during your dictation. \(ignored(after: landed))" }
}

/// A press whose audio the capture could not hand over whole, reported instead of inserted.
///
/// Every door leaves the same thing in the user's editor, which is why they arrive here
/// as one failure rather than several. Which doors there are is `CapturedAudio.Loss`'s to
/// say, and `lost` carries the ones this press took. [LAW:one-source-of-truth]
///
/// [LAW:no-silent-failure] Nothing more is inserted once it is known, for the reason
/// `PressLapsed` gives: what a fragment transcribes to is a sentence, just not the one
/// that was said. Words committed while the press was open stay, and this says how many.
public struct SpeechLost: WordFree {
    /// The chord that was down while the audio went missing.
    public let chord: KeyChord
    public let lost: CapturedAudio.Loss
    /// The words committed before it was known.
    public let landed: Int

    public var description: String { "WARNING: \(lost). \(ignored(after: landed))" }
}

/// A press that stopped after it began: an insert refused, the engine failed, or what was
/// left at key-up would not go in. The words before it are at the cursor, and the rest of
/// the press went nowhere. [LAW:no-silent-failure]
///
/// Word-free whatever stopped it: a cause that could carry words is named by its type.
public struct PressStopped: StoppedPartWay, WordFree {
    /// The words committed before it stopped.
    public let landed: Int
    public let cause: any Error

    public var description: String {
        let root = cause.causes.last ?? cause
        return ((root as? any WordFree).map { "\($0)" } ?? "It stopped on \(type(of: root)).") + insertedBefore(landed)
    }
}

/// What the menu tells the person who dictated about a press that failed: what stopped it,
/// in full, since only they read it, and how many of their words it left at the cursor.
/// A failure written as fact then consequence opens with WARNING and carries its own framing;
/// any other is a bare technical line, so it is told what it is.
public func failureLine(_ failure: any Error) -> String {
    let root = "\(failure.causes.last ?? failure)"
    let landed = (failure as? PressStopped)?.landed ?? 0
    let framed = root.hasPrefix("WARNING:") ? root : "Your last dictation \(landed == 0 ? "was not placed" : "stopped"): \(root)"
    return framed + insertedBefore(landed)
}

/// How many of a press's words reached the cursor before what stopped it, when any did.
private func insertedBefore(_ landed: Int) -> String {
    landed == 0 ? "" : " \(landed) words of your dictation were inserted before it; the rest were not."
}

/// What became of a press's words, after however many had landed.
private func ignored(after landed: Int) -> String {
    landed == 0 ? "Your dictation was ignored." : "The \(landed) words already inserted stay; the rest of your dictation was ignored."
}
