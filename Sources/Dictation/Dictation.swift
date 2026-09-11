import KeyboardLayout
import LowTalkerCore
import Typing

/// The loop from a press of the hotkey to words in the app: key-down names the app in
/// front and opens the microphone, marking where the utterance begins on the ring;
/// key-up ends it and closes the microphone again; and what was said is heard, routed
/// and typed while the next press can already begin.
///
/// [LAW:decomposition] Presses in, sessions out. The microphone, the engine, the
/// router and the keyboard are values it is given, so the whole loop runs in a test
/// against a fake of each and the app's delegate only hands over the real ones. The
/// tap is not among them: it is fed `press`, and what installs it is not this loop's
/// concern. [LAW:composability]
///
/// [LAW:no-ambient-temporal-coupling] Sessions are heard and typed on one serial
/// queue, so two presses in quick succession type in the order they were spoken and
/// never interleave, however long the engine takes on either. Key-down and key-up run
/// inside the tap's callback, where a slow handler is what makes macOS switch the tap
/// off, so what they do is counted: one read of which app is in front, two ring
/// positions, and the microphone opening and shutting. The opening is the expensive
/// one - 39 ms of `AVAudioEngine.start` on this Mac, 240 ms for the first press after
/// launch - and it is spent here rather than behind an await because an engine started
/// off the callback would start later still, and every millisecond of it is speech the
/// microphone was not open for. Sessions are typed on this same actor, so the typing
/// awaits each key's acknowledgement rather than holding the actor for it: a press made
/// in the middle of an insert is marked on the ring when it is made.
@MainActor
public final class Dictation {
    /// One press the speaker ended, done: where it went, what was heard, how long after
    /// key-up, and what was typed. An utterance with nothing said in it is a session
    /// that performed nothing, not a failure.
    ///
    /// [LAW:types-are-the-program] A press the tap lapsed out of never reaches one of
    /// these, and neither does one whose audio the ring could not hand over whole; those
    /// are reported as `PressLapsed` and `SpeechLost`. What is left is the press this
    /// type says it is: one the speaker ended, heard from every sample it covered.
    public struct Session: Sendable, CustomStringConvertible {
        public let context: Context
        public let transcript: Transcript
        /// From the key coming up to the transcript, the engine's share of the wait.
        public let keyUpToTranscript: Duration
        public let performed: [Executor.Performed]

        /// The session in numbers, without the words: they are what the user
        /// dictated, and each surface decides for itself whether to show them.
        /// [LAW:one-source-of-truth] The app's log line and the CLI's are this, and
        /// where the words went is read off what was performed rather than off the app
        /// that happened to be in front at key-down: a route may name its own target,
        /// and then the two are different apps.
        public var description: String {
            let into = Set(performed.map(\.into)).map(\.rawValue).sorted().joined(separator: ", ")
            let destination = into.isEmpty ? "" : " into \(into)"
            return "heard \(transcript.words.count) words \(Int(keyUpToTranscript / .milliseconds(1))) ms after key-up, \(performed.count) actions\(destination)"
        }
    }

    /// What key-down left for key-up: the marks on the ring and the app in front, or
    /// the reason there was nothing to type into. [LAW:types-are-the-program] One
    /// value rather than an optional session beside an optional app, so an end can
    /// never find half a beginning.
    private enum Press {
        case up
        case down(AudioSession, into: BundleID)
        case refused(any Error)
    }

    private let capture: AudioCapture
    private let transcriber: @Sendable @MainActor () async throws -> any Transcriber
    private let router: Router
    private let executor: Executor
    private let layout: @Sendable @MainActor () throws -> KeyboardLayout
    private let frontmost: @Sendable @MainActor () throws -> BundleID
    private let report: @Sendable @MainActor (Result<Session, any Error>) -> Void
    private var press: Press = .up
    private let sessions = SerialQueue()

    /// `transcriber` is awaited per session, so a press that comes while the model is
    /// still loading waits for it and types when it lands: loading is not a state
    /// this loop has. [LAW:dataflow-not-control-flow] `layout` is read per session,
    /// since the user can switch layouts between two presses. `report` hears every
    /// session's outcome on the main actor, in the order the presses came.
    public init(
        capture: AudioCapture,
        transcriber: @escaping @Sendable @MainActor () async throws -> any Transcriber,
        router: Router,
        executor: Executor,
        layout: @escaping @Sendable @MainActor () throws -> KeyboardLayout = KeyboardLayout.current,
        frontmost: @escaping @Sendable @MainActor () throws -> BundleID = TargetApp.frontmost,
        report: @escaping @Sendable @MainActor (Result<Session, any Error>) -> Void
    ) {
        self.capture = capture
        self.transcriber = transcriber
        self.router = router
        self.executor = executor
        self.layout = layout
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
            do {
                // The app in front before the microphone, so a reading that throws cannot
                // leave a microphone open with no session to close it; it is one read of
                // the workspace, which the engine's start dwarfs. [LAW:no-ambient-temporal-coupling]
                let into = try frontmost()
                // The mark comes from the event's own stamp, so a key-down the tap
                // delivered late marks the ring where the key went down. What the mark
                // can reach back over is another matter: this is also where the
                // microphone opens, and an engine that has just started has nothing
                // behind it, so the pre-roll pads a press only while some earlier
                // session's engine is still running.
                press = .down(try capture.beginSession(at: moment), into: into)
            } catch {
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
            // being typed. [LAW:dataflow-not-control-flow]
            let heard: Result<(AudioClip, Context), any Error>
            switch open {
            case .up:
                preconditionFailure("a press ended that never began; the detector pairs every ended with a began")
            case .refused(let error):
                heard = .failure(error)
            case .down(let session, let into):
                // The marks are closed and the microphone with them, however the press
                // ended, so a session left open cannot carry its beginning into the next
                // press's clip and cannot leave the device held after the key came up.
                let audio = capture.endSession(session)
                // What there was to hear, read once. [LAW:no-silent-failure] A tap that
                // lapsed and audio the capture could not hand over whole each leave
                // something this loop must not report as an utterance. The lapse is asked
                // first: a press the tap lapsed out of says so rather than describing the
                // clip it left behind, which was never the whole utterance anyway. A
                // microphone that was not there at all was refused at key-down, so it
                // never reaches here. The focused element's role is a synchronous call
                // into another process, up to half a second of it, which the tap's
                // callback cannot afford; a route that wants it reads it off this thread.
                heard = switch (ending, audio) {
                case (.lapsed, _): .failure(PressLapsed(chord: chord))
                case (.released(let kind), .whole(let clip)):
                    .success((clip, Context(chord: chord, press: kind, frontmostApp: into, focusedElementRole: nil)))
                case (.released, .partial(_, let lost)): .failure(SpeechLost(chord: chord, lost: lost))
                }
            }
            do {
                // Handed over before key-up returns, so a `finish` that comes next
                // cannot miss this press. Reported from inside the operation, so the
                // queue that orders the typing orders the telling of it too, and a
                // drain that waited for the one has waited for the other.
                // [LAW:no-ambient-temporal-coupling] [LAW:single-enforcer]
                try sessions.submit { [report] in
                    let outcome: Result<Session, any Error>
                    do {
                        let (clip, context) = try heard.get()
                        outcome = .success(try await self.hear(clip, in: context, since: keyUp))
                    } catch {
                        outcome = .failure(error)
                    }
                    await report(outcome)
                }
            } catch {
                // The operation reports its own outcome; only the queue's own refusal
                // to accept it reaches here. [LAW:no-silent-failure]
                report(.failure(error))
            }
        }
    }

    /// Returns once every session already begun has been typed and reported.
    ///
    /// [LAW:no-ambient-temporal-coupling] A session holds keys down while it types and
    /// releases them on its way out, so a process that exits while one is in flight
    /// leaves a key down for macOS to repeat into whatever comes forward next. This is
    /// what a surface awaits before it goes, and the wait is on the sessions themselves
    /// rather than on a grace period long enough to probably cover them.
    public func finish() async throws {
        try await sessions.drain()
    }

    private func hear(_ clip: AudioClip, in context: Context, since keyUp: ContinuousClock.Instant) async throws -> Session {
        let engine = try await transcriber()
        let transcript = try await engine.transcribe(clip, expecting: .empty)
        let keyUpToTranscript = ContinuousClock.now - keyUp
        let actions = router.actions(for: transcript, in: context)
        let performed = try await executor.perform(actions, in: context, on: try layout(), since: keyUp)
        return Session(context: context, transcript: transcript, keyUpToTranscript: keyUpToTranscript, performed: performed)
    }
}

/// A press the tap stopped hearing partway through, reported instead of typed.
///
/// The tap went deaf while the key was down, so what was captured runs from the press
/// to the lapse rather than to the release, and whether the speaker had even finished
/// is unknown - the release may be among the events that were lost.
///
/// [LAW:no-silent-failure] Typing a fragment is the one thing this must not do. Half a
/// sentence arrives unmarked as half, and it cannot be marked: the destination is the
/// user's editor, not this app's, and once the words are in it nothing here can say
/// which ones were missing - the user may not notice at all, and may send it. A press
/// that says it lost the keyboard is a thing they can act on by saying it again, which
/// is the same thing they would have to do anyway.
public struct PressLapsed: Error, CustomStringConvertible {
    /// The chord that was down when the tap lapsed.
    public let chord: KeyChord

    public var description: String { "the keyboard tap lapsed during a press of \(chord); what was said was not typed" }
}

/// A press whose audio the capture could not hand over whole, reported instead of typed.
///
/// Every door leaves the same thing in the user's editor. The ring retains only so much,
/// so a hold longer than that loses its head to its own tail; capture restarts when the
/// input device changes - AirPods connecting mid-sentence - which splices the audio on
/// either side of the change together with an unknown stretch missing between; and the
/// microphone opens for the press rather than for the app, so a hold shorter than the
/// engine takes to start ends before a sample of it was ever captured, and one whose
/// key-down reached the loop late begins after the words it was pressed for.
///
/// [LAW:no-silent-failure] Typing it is the one thing this must not do, for the reason
/// `PressLapsed` gives: what a fragment transcribes to is a sentence, just not the one
/// that was said, and it arrives in the user's editor unmarked as a fragment where
/// nothing here can mark it. A press that says what it lost is something the speaker can
/// act on by saying it again.
public struct SpeechLost: Error, CustomStringConvertible {
    /// The chord that was down while the audio went missing.
    public let chord: KeyChord
    public let lost: CapturedAudio.Loss

    public var description: String { "the audio of a press of \(chord) is \(lost); what was said was not typed" }
}
