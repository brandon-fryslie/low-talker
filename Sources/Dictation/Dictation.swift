import KeyboardLayout
import LowTalkerCore
import Typing

/// The loop from a press of the hotkey to words in the app: key-down marks where the
/// utterance begins on the ring and names the app in front, key-up ends it, and what
/// was said is heard, routed and typed while the next press can already begin.
///
/// [LAW:decomposition] Presses in, sessions out. The microphone, the engine, the
/// router and the keyboard are values it is given, so the whole loop runs in a test
/// against a fake of each and the app's delegate only hands over the real ones. The
/// tap is not among them: it is fed `press`, and what installs it is not this loop's
/// concern. [LAW:composability]
///
/// [LAW:no-ambient-temporal-coupling] Sessions are heard and typed on one serial
/// queue, so two presses in quick succession type in the order they were spoken and
/// never interleave, however long the engine takes on either. Key-down and key-up
/// themselves do almost nothing - a ring position, one read of which app is in
/// front - because they run inside the tap's callback, where a slow handler is what
/// makes macOS switch the tap off. Sessions are typed on this same actor, so the typing
/// awaits each key's acknowledgement rather than holding the actor for it: a press made
/// in the middle of an insert is marked on the ring when it is made.
@MainActor
public final class Dictation {
    /// One press, done: where it went, what was heard, how long after key-up, and what
    /// was typed. An utterance with nothing said in it is a session that performed
    /// nothing, not a failure.
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
        case .began:
            guard case .up = press else { preconditionFailure("a press began while one was open; the detector pairs every began with an ended") }
            // The mark first: the ring is running either way, and the earlier the mark
            // the less the pre-roll has to reach back for.
            let session = capture.beginSession()
            do {
                press = .down(session, into: try frontmost())
            } catch {
                press = .refused(error)
            }
        case .ended(let chord, let kind):
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
                let clip = capture.endSession(session)
                // The role is a synchronous call into another process, up to half a
                // second of it, which the tap's callback cannot afford; a route that
                // reads it is where it gets read, off this thread.
                let context = Context(chord: chord, press: kind, frontmostApp: into, focusedElementRole: nil)
                // [LAW:no-silent-failure] Read at key-up, once: a microphone that
                // stopped mid-hold leaves a ring the engine would hear as silence and
                // this loop would report as nothing said.
                heard = switch capture.state {
                case .running: .success((clip, context))
                case .stopped: .failure(NoMicrophone.stopped)
                case .failed(let error): .failure(NoMicrophone.failed(error))
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

/// A press with no microphone behind it.
public enum NoMicrophone: Error, CustomStringConvertible {
    /// Capture was never started, or has been stopped.
    case stopped
    /// Capture stopped on its own and has not recovered.
    case failed(any Error)

    public var description: String {
        switch self {
        case .stopped: "the microphone is not being captured; nothing was heard"
        case .failed(let error): "microphone capture failed: \(error); nothing was heard"
        }
    }
}
