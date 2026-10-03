import LowTalkerCore
import Synchronization

/// The loop from a press of the hotkey to words at the cursor: key-down names the app in
/// front and opens the microphone, marking where the utterance begins on the ring, and the
/// engine starts hearing it as it is captured; key-up ends it and closes the microphone
/// again; and the transcript is routed and inserted while the next press can already begin.
///
/// [LAW:decomposition] Presses in, sessions out. The microphone, the engine, the
/// router and the input method are values it is given, so the whole loop runs in a test
/// against a fake of each and the app's delegate only hands over the real ones. The
/// hotkey is not among them: it is fed `press`, and what starts it is not this loop's
/// concern. [LAW:composability]
///
/// [LAW:no-ambient-temporal-coupling] Sessions are heard and inserted on one serial
/// queue, so two presses in quick succession insert in the order they were spoken and
/// never interleave, however long the engine takes on either. Key-down and key-up reach
/// this from the main queue, as the hotkey hands them on.
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

    /// What a press's decode showed while the key was still down: the passes it had run,
    /// and how long after the key went down the first of them read any words.
    public struct DuringPress: Sendable, CustomStringConvertible {
        public let passes: Int
        /// [LAW:types-are-the-program] Absent when no pass before key-up read a word,
        /// which a short tap or a slow engine leaves - not a zero, which would say the
        /// words were there at once.
        public let firstWords: Duration?

        public var description: String {
            let words = firstWords.map { "first words \(Int($0 / .milliseconds(1))) ms after key-down" } ?? "no words before key-up"
            return "\(passes) passes during the press, \(words)"
        }
    }

    /// The partials of one press's decode, counted as they come. Read once, at key-up:
    /// what the snapshot holds is what the press showed while it was open, and a pass that
    /// ends after it changes a count nobody reads again.
    private final class Partials: Sendable {
        private let keyDown: HostTime
        private let seen = Mutex(DuringPress(passes: 0, firstWords: nil))

        init(since keyDown: HostTime) {
            self.keyDown = keyDown
        }

        func heard(_ partial: Partial) {
            let now = HostTime.now
            seen.withLock { seen in
                let words = partial.text.isEmpty ? nil : now - keyDown
                seen = DuringPress(passes: seen.passes + 1, firstWords: seen.firstWords ?? words)
            }
        }

        var atKeyUp: DuringPress { seen.withLock { $0 } }
    }

    /// A press's decode, begun at key-down: the transcript it came to, when, and what the
    /// press's hold put off. The hold is let go inside it the moment the transcript is out,
    /// so served callers wait for this press's engine and not for an earlier press's insert.
    private struct Decoded: Sendable {
        let transcript: Result<Transcript, any Error>
        let at: ContinuousClock.Instant
        let displaced: EngineHold.Displaced
    }

    /// What key-down left for key-up: the marks on the ring, the app in front and the
    /// decode already hearing the press, or the reason there was nothing to insert into.
    /// [LAW:types-are-the-program] One value rather than an optional session beside an
    /// optional app, so an end can never find half a beginning.
    private enum Press {
        case up
        case down(AudioSession, into: BundleID, Task<Decoded, Never>, Partials)
        case refused(any Error, Task<Decoded, Never>)
    }

    private let capture: AudioCapture
    private let transcriber: @Sendable @MainActor () async throws -> any Transcriber
    private let turns: EngineTurns
    private let router: Router
    private let executor: Executor
    private let frontmost: @Sendable @MainActor () throws -> BundleID
    private let report: @Sendable @MainActor (Result<Session, any Error>) -> Void
    private var press: Press = .up
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
            // and taken by every press, refused or not: each press releases its hold by the
            // one path its session ends on. [LAW:dataflow-not-control-flow]
            let hold = turns.hold()
            do {
                // The app in front before the microphone, so a reading that throws cannot
                // leave a microphone open with no session to close it; it is one read of
                // the workspace, which the engine's start dwarfs. [LAW:no-ambient-temporal-coupling]
                let into = try frontmost()
                // The mark comes from the event's own stamp, so a key-down told late
                // marks the ring where the key went down. What it reaches
                // back over is the resting mode's to say: nothing behind a microphone that
                // opens here, and the look-back behind one held open since `start()`.
                let session = try capture.beginSession(at: moment)
                let partials = Partials(since: moment)
                press = .down(session, into: into, decode(capture.audio(of: session), into: partials, releasing: hold), partials)
            } catch {
                let displaced = hold.release()
                press = .refused(error, Task { Decoded(transcript: .failure(error), at: .now, displaced: displaced) })
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
            let heard: Result<(Context, DuringPress), any Error>
            let decode: Task<Decoded, Never>
            switch open {
            case .up:
                preconditionFailure("a press ended that never began; the detector pairs every ended with a began")
            case .refused(let error, let decoding):
                heard = .failure(error)
                decode = decoding
            case .down(let session, let into, let decoding, let partials):
                decode = decoding
                // Read before the session ends, so it holds only what the press showed
                // while it was open.
                let duringPress = partials.atKeyUp
                // The marks are closed and the microphone with them, however the press
                // ended, so a session left open cannot carry its beginning into the next
                // press's clip and cannot leave the device held after the key came up.
                // Its audio ends here too, which is what lets the decode finish.
                let audio = capture.endSession(session)
                // What there was to hear, read once. [LAW:no-silent-failure] A hotkey that
                // stopped and audio the capture could not hand over whole each leave
                // something this loop must not report as an utterance. The lapse is asked
                // first: a press the hotkey stopped during says so rather than describing the
                // clip it left behind, which was never the whole utterance anyway. A
                // microphone that was not there at all was refused at key-down, so it
                // never reaches here. The focused element's role is a synchronous call
                // into another process, up to half a second of it, and this is the main
                // actor: a press waits on it, and so does every window this app draws.
                // A route that wants the role reads it off this thread.
                heard = switch (ending, audio) {
                case (.lapsed, _): .failure(PressLapsed(chord: chord))
                case (.released(let kind), .whole):
                    .success((Context(chord: chord, press: kind, frontmostApp: into, focusedElementRole: nil), duringPress))
                case (.released, .partial(_, let lost)): .failure(SpeechLost(chord: chord, lost: lost))
                }
            }
            // A press that will not be inserted has no use for the rest of its decode, and
            // the engine goes back to whoever is waiting as soon as it stops.
            if case .failure = heard { decode.cancel() }
            do {
                // Handed over before key-up returns, so a `finish` that comes next
                // cannot miss this press. Reported from inside the operation, so the
                // queue that orders the inserts orders the telling of it too, and a
                // drain that waited for the one has waited for the other.
                // [LAW:no-ambient-temporal-coupling] [LAW:single-enforcer]
                try sessions.submit { [report] in
                    let outcome: Result<Session, any Error>
                    do {
                        outcome = .success(try await self.hear(heard, decode, since: keyUp))
                    } catch {
                        outcome = .failure(error)
                    }
                    await report(outcome)
                }
            } catch {
                // The operation reports its own outcome; only the queue's own refusal
                // to accept it reaches here, and then nothing will ever read the decode, so
                // it is stopped and lets go of the engine as it does. [LAW:no-silent-failure]
                decode.cancel()
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
    /// engine as it is captured, and the transcript is what the engine makes of it once the
    /// key comes up and the audio ends. [LAW:one-type-per-behavior] A held press and a
    /// toggled one are heard the same way; how the press was made is the context's to say.
    ///
    /// The hold ends with the transcript, whatever became of it: the insert that follows is
    /// not the engine's, and served callers wait for this press and no longer.
    private func decode(_ audio: AsyncStream<AudioClip>, into partials: Partials, releasing hold: EngineHold) -> Task<Decoded, Never> {
        Task { [transcriber] in
            let transcript: Result<Transcript, any Error>
            do {
                transcript = .success(try await transcriber().transcribe(audio, expecting: .empty) { partials.heard($0) })
            } catch {
                transcript = .failure(error)
            }
            return Decoded(transcript: transcript, at: .now, displaced: hold.release())
        }
    }

    /// Waits for the press's decode, then routes and inserts what it heard. The decode is
    /// awaited even for a press that will not be inserted, so the press is reported once its
    /// engine has stopped and not while it is still running.
    private func hear(_ heard: Result<(Context, DuringPress), any Error>, _ decode: Task<Decoded, Never>, since keyUp: ContinuousClock.Instant) async throws -> Session {
        let decoded = await decode.value
        let (context, duringPress) = try heard.get()
        let transcript = try decoded.transcript.get()
        let actions = router.actions(for: transcript, in: context)
        let performed = try await executor.perform(actions, since: keyUp)
        return Session(context: context, transcript: transcript, duringPress: duringPress, keyUpToTranscript: decoded.at - keyUp, displaced: decoded.displaced, performed: performed)
    }
}

/// A press the hotkey stopped hearing partway through, reported instead of inserted.
///
/// The hotkey stopped while the key was down - the app rebuilding its loop, or quitting -
/// so what was captured runs from the press to the stop rather than to the release, and
/// whether the speaker had even finished is unknown.
///
/// [LAW:no-silent-failure] Inserting a fragment is the one thing this must not do. Half a
/// sentence arrives unmarked as half, and it cannot be marked: the destination is the
/// user's editor, not this app's, and once the words are in it nothing here can say
/// which ones were missing - the user may not notice at all, and may send it. A press
/// that says it was cut off is a thing they can act on by saying it again, which is the
/// same thing they would have to do anyway.
public struct PressLapsed: WordFree {
    /// The chord that was down when the hotkey stopped.
    public let chord: KeyChord

    public var description: String { "WARNING: The hotkey stopped listening during your dictation. Your dictation was ignored." }
}

/// A press whose audio the capture could not hand over whole, reported instead of inserted.
///
/// Every door leaves the same thing in the user's editor, which is why they arrive here
/// as one failure rather than several. Which doors there are is `CapturedAudio.Loss`'s to
/// say, and `lost` carries the ones this press took. [LAW:one-source-of-truth]
///
/// [LAW:no-silent-failure] Inserting it is the one thing this must not do, for the reason
/// `PressLapsed` gives: what a fragment transcribes to is a sentence, just not the one
/// that was said, and it arrives in the user's editor unmarked as a fragment where
/// nothing here can mark it. A press that says what it lost is something the speaker can
/// act on by saying it again.
public struct SpeechLost: WordFree {
    /// The chord that was down while the audio went missing.
    public let chord: KeyChord
    public let lost: CapturedAudio.Loss

    public var description: String { "WARNING: \(lost). Your dictation was ignored." }
}
