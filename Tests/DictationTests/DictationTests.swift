import Dictation
import KeyboardLayout
import LowTalkerCore
import Synchronization
import Testing
import Typing

private struct NoEngine: Error {}
private struct NoApp: Error {}
private struct BadBuffer: Error {}

/// The loop with a fake behind every seam: the microphone is fed by hand, the engine
/// answers as scripted, the keyboard keeps a log, and every session's report is
/// awaited off a stream rather than polled for.
@MainActor
final class Rig {
    static let us = try! KeyboardLayout.named("com.apple.keylayout.US")
    static let textEdit = BundleID(rawValue: "com.apple.TextEdit")
    static let rightOption = Hotkey.defaultChord
    /// The executor needs a pointer; a dictation session must never post to one, so the
    /// screen behind it answers nothing a report could be aimed at.
    @MainActor static let unusedPointer = Pointer(
        mouse: UnusedMouse(),
        cursor: { ScreenPoint(x: 0, y: 0) },
        locate: { role, title in throw UnusedMouse.Pointed(report: "a search for \(role.rawValue) titled \(title)") }
    )

    let hardware = FakeHardware()
    let capture: AudioCapture
    let keyboard = LoggingKeyboard()
    let dictation: Dictation
    private let reports: AsyncStream<Result<Dictation.Session, any Error>>

    init(
        transcriber: @escaping @Sendable @MainActor () async throws -> any Transcriber,
        frontmost: @escaping @Sendable @MainActor () throws -> BundleID = { textEdit }
    ) throws {
        capture = AudioCapture(hardware: hardware)
        try capture.start(try MicrophonePermission(authority: Authorized()).current.grant())
        let (stream, feed) = AsyncStream.makeStream(of: Result<Dictation.Session, any Error>.self)
        reports = stream
        let keyboard = keyboard
        dictation = Dictation(
            capture: capture,
            transcriber: transcriber,
            router: Router(routes: [.dictation]),
            executor: Executor(keyboard: { _ in keyboard }, mouse: { _ in Self.unusedPointer }, hotkeys: [Self.rightOption]),
            layout: { Self.us },
            frontmost: frontmost,
            report: { feed.yield($0) }
        )
    }

    convenience init(hearing transcriber: FakeTranscriber) throws {
        try self.init(transcriber: { transcriber })
    }

    /// A hold of the hotkey with `samples` captured during it.
    func hold(speaking samples: [Float] = [1, 2, 3]) {
        dictation.press(.began(Self.rightOption))
        hardware.engines[0].appending(samples)
        dictation.press(.ended(Self.rightOption, .hold))
    }

    /// The next session's outcome, in press order.
    func report() async -> Result<Dictation.Session, any Error> {
        for await outcome in reports { return outcome }
        preconditionFailure("the report stream ended while a test was still reading it")
    }

    func session() async throws -> Dictation.Session {
        try await report().get()
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

@MainActor
@Suite struct DictationTests {
    /// The keystrokes `LoggingKeyboard` records for a character on the US layout.
    private static func typed(_ character: Character) -> [String] {
        ["check", "down \(String(try! Rig.us.keystrokes(for: String(character))[0].usage.rawValue, radix: 16))", "up"]
    }

    @Test func aHoldTypesWhatWasSaidIntoTheAppThatWasInFront() async throws {
        let engine = FakeTranscriber { _ in Transcript(typed: "hi") }
        let rig = try Rig(hearing: engine)
        rig.hold(speaking: [1, 2, 3])
        let session = try await rig.session()
        #expect(engine.clips.map(\.samples) == [[1, 2, 3]])
        #expect(session.transcript.text == "hi")
        #expect(session.context.frontmostApp == Rig.textEdit)
        #expect(session.context.press == .hold)
        #expect(session.performed.count == 1)
        #expect(session.performed[0].into == Rig.textEdit)
        #expect(session.keyUpToTranscript >= .zero)
        #expect(rig.keyboard.log == Self.typed("h") + Self.typed("i"))
    }

    /// The audio is what the ring held between the marks; a press that starts after
    /// speech began still holds it through the pre-roll.
    @Test func theEngineHearsOnlyTheHold() async throws {
        let engine = FakeTranscriber { _ in Transcript(typed: "") }
        let rig = try Rig(hearing: engine)
        rig.hardware.engines[0].appending(Array(repeating: 0, count: AudioClip.sampleCount(for: AudioSession.defaultPreRoll) + 2))
        rig.hold(speaking: [7, 8])
        _ = try await rig.session()
        let heard = try #require(engine.clips.first?.samples)
        #expect(heard.count == AudioClip.sampleCount(for: AudioSession.defaultPreRoll) + 2)
        #expect(heard.suffix(2) == [7, 8])
    }

    @Test func nothingSaidIsASessionThatTypesNothing() async throws {
        let rig = try Rig(hearing: FakeTranscriber { _ in Transcript(typed: "") })
        rig.hold()
        let session = try await rig.session()
        #expect(session.performed.isEmpty)
        #expect(rig.keyboard.log.isEmpty)
    }

    /// A press before the model is resident waits for it; loading is not a refusal.
    @Test func aPressWhileTheEngineLoadsWaitsForIt() async throws {
        let gate = Gate()
        let engine = FakeTranscriber { _ in Transcript(typed: "a") }
        let rig = try Rig { await gate.wait(); return engine }
        rig.hold()
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { gate.waiting == 1 })
        #expect(rig.keyboard.log.isEmpty)
        gate.open()
        _ = try await rig.session()
        #expect(rig.keyboard.log == Self.typed("a"))
    }

    /// Two presses type in the order they were spoken: the second is not heard until
    /// the first is typed, so the words of one can never land inside the other's.
    @Test func sessionsAreHeardAndTypedInOrder() async throws {
        let gate = Gate()
        let engine = FakeTranscriber { clip in
            // The first hold says "a" and waits; the second says "b" at once.
            if clip.samples == [1] { await gate.wait() }
            return Transcript(typed: clip.samples == [1] ? "a" : "b")
        }
        let rig = try Rig(hearing: engine)
        rig.hold(speaking: [1])
        rig.hold(speaking: [2])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { gate.waiting == 1 })
        #expect(engine.clips.count == 1)
        gate.open()
        let first = try await rig.session()
        let second = try await rig.session()
        #expect(first.transcript.text == "a")
        #expect(second.transcript.text == "b")
        #expect(rig.keyboard.log == Self.typed("a") + Self.typed("b"))
    }

    @Test func aPressWithNothingToTypeIntoIsReportedAndTheNextPressTypes() async throws {
        let refused = Mutex(true)
        let rig = try Rig(transcriber: { FakeTranscriber { _ in Transcript(typed: "a") } }) {
            if refused.withLock({ $0 }) { throw NoApp() }
            return Rig.textEdit
        }
        rig.hold()
        #expect(await rig.report().failure is NoApp)
        refused.withLock { $0 = false }
        rig.hold()
        _ = try await rig.session()
        #expect(rig.keyboard.log == Self.typed("a"))
    }

    @Test func anEngineThatFailsIsReportedAndTheNextPressTypes() async throws {
        let failing = Mutex(true)
        let rig = try Rig(hearing: FakeTranscriber { _ in
            if failing.withLock({ $0 }) { throw NoEngine() }
            return Transcript(typed: "a")
        })
        rig.hold()
        #expect(await rig.report().failure is NoEngine)
        failing.withLock { $0 = false }
        rig.hold()
        _ = try await rig.session()
        #expect(rig.keyboard.log == Self.typed("a"))
    }

    /// A keyboard that refuses stops the session with what was done, as the executor
    /// says it; the loop adds nothing and goes on to the next press.
    @Test func aRefusedKeystrokeIsReportedAsTheRouteStopping() async throws {
        let rig = try Rig(hearing: FakeTranscriber { _ in Transcript(typed: "a") })
        rig.keyboard.refusing = true
        rig.hold()
        let stopped = try #require(await rig.report().failure as? RouteStopped)
        #expect(stopped.cause is TypingStopped)
        #expect(stopped.performed.isEmpty)
    }

    /// [LAW:no-silent-failure] A microphone that failed leaves a ring the engine would
    /// hear as silence; the session says so instead of typing nothing.
    @Test func aPressAfterCaptureFailedIsReportedNotHeardAsSilence() async throws {
        let engine = FakeTranscriber { _ in Transcript(typed: "a") }
        let rig = try Rig(hearing: engine)
        rig.hardware.engines[0].onFailure(BadBuffer())
        rig.hold()
        let failure = try #require(await rig.report().failure as? NoMicrophone)
        guard case .failed(let error) = failure else { Issue.record("expected the capture's failure, got \(failure)"); return }
        #expect(error is BadBuffer)
        #expect(engine.clips.isEmpty)
    }
}
