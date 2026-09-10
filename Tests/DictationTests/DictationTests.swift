import Dictation
import KeyboardLayout
import LowTalkerCore
import Synchronization
import Testing
import TestProbes
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
    /// Raised by the first outcome to be reported. The stream says what the next report
    /// is, this says whether one has come at all - the difference a `finish` that
    /// returned before its session was reported would show.
    let reported = Flag()

    init(
        transcriber: @escaping @Sendable @MainActor () async throws -> any Transcriber,
        router: Router = Router(routes: [.dictation]),
        frontmost: @escaping @Sendable @MainActor () throws -> BundleID = { textEdit }
    ) throws {
        capture = AudioCapture(hardware: hardware)
        try capture.start(try MicrophonePermission(authority: Authorized()).current.grant())
        let (stream, feed) = AsyncStream.makeStream(of: Result<Dictation.Session, any Error>.self)
        reports = stream
        let keyboard = keyboard
        let reported = reported
        dictation = Dictation(
            capture: capture,
            transcriber: transcriber,
            router: router,
            executor: Executor(keyboard: { _ in keyboard }, mouse: { _ in Self.unusedPointer }, hotkeys: [Self.rightOption]),
            layout: { Self.us },
            frontmost: frontmost,
            report: { outcome in
                reported.raise()
                feed.yield(outcome)
            }
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

    /// A hold made while a session is typing is marked when it is made, not when the typing
    /// is done. The first session is held at its first key-down, waiting on the device as
    /// every key-down does, and the second hold happens then: silence up to its key-down,
    /// its words between the marks, a sample after its key-up. A mark that waited for the
    /// typing would be made after the last of them, and the clip would show it.
    @Test func aHoldMadeWhileASessionIsTypingIsMarkedWhenItIsMade() async throws {
        let gate = Gate()
        let engine = FakeTranscriber { clip in Transcript(typed: clip.samples == [1] ? "a" : "b") }
        let rig = try Rig(hearing: engine)
        rig.keyboard.acknowledgement = { await gate.wait() }
        rig.hold(speaking: [1])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { gate.waiting == 1 })
        #expect(rig.keyboard.log == Array(Self.typed("a").prefix(2)))

        let silence = [Float](repeating: 0, count: AudioClip.sampleCount(for: AudioSession.defaultPreRoll))
        rig.hardware.engines[0].appending(silence)
        rig.hold(speaking: [7, 8])
        rig.hardware.engines[0].appending([9])
        #expect(rig.keyboard.log == Array(Self.typed("a").prefix(2)))

        gate.open()
        #expect(try await rig.session().transcript.text == "a")
        #expect(try await rig.session().transcript.text == "b")
        #expect(engine.clips.last?.samples == silence + [7, 8])
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

    /// A press with nothing to type into is refused at key-down, before anything is
    /// heard, so it is the one outcome that could be ready before an earlier press's.
    /// It waits its turn all the same: outcomes are reported in the order the presses
    /// came, whatever each one costs.
    @Test func aRefusedPressIsReportedAfterAnEarlierPressStillBeingHeard() async throws {
        let gate = Gate()
        let refusing = Mutex(false)
        let rig = try Rig(transcriber: {
            FakeTranscriber { _ in
                await gate.wait()
                return Transcript(typed: "a")
            }
        }) {
            if refusing.withLock({ $0 }) { throw NoApp() }
            return Rig.textEdit
        }
        rig.hold()
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { gate.waiting == 1 })
        refusing.withLock { $0 = true }
        rig.hold()
        gate.open()
        let first = await rig.report()
        let second = await rig.report()
        #expect(try first.get().transcript.text == "a")
        #expect(second.failure is NoApp)
    }

    /// What `lowtalker dictate` awaits before it goes. A session holds keys down while
    /// it types and releases them on its way out, so a surface that went while one was
    /// still in flight would leave a key down for macOS to repeat into whatever came
    /// forward next. The session is held at the engine with nothing typed yet, so a
    /// `finish` that did not wait is caught by the empty keyboard log - and by the
    /// report not having landed, which is the other half of what `finish` promises.
    @Test func finishReturnsOnlyAfterASessionStillInFlightHasTypedAndBeenReported() async throws {
        let gate = Gate()
        let rig = try Rig(transcriber: {
            FakeTranscriber { _ in
                await gate.wait()
                return Transcript(typed: "a")
            }
        })
        rig.hold()
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { gate.waiting == 1 })
        #expect(rig.keyboard.log.isEmpty)
        #expect(!rig.reported.raised)
        gate.open()
        try await rig.dictation.finish()
        #expect(rig.keyboard.log == Self.typed("a"))
        #expect(rig.reported.raised)
    }

    /// The other half of the same contract, at the loop: `press(.ended)` puts the session
    /// on the queue before it returns, so a `finish` with nothing awaited between it and
    /// the key-up is still owed that session's wait. What this pins is that guarantee, not
    /// the window it closed - after submission became synchronous there is no window left
    /// here to reach, and a test that claimed to reproduce one would be claiming more than
    /// it does. [LAW:behavior-not-structure]
    @Test func finishRightAfterAKeyUpWaitsForThatPressWithNothingAwaitedInBetween() async throws {
        let rig = try Rig(hearing: FakeTranscriber { _ in Transcript(typed: "a") })
        rig.hold()
        try await rig.dictation.finish()
        #expect(rig.keyboard.log == Self.typed("a"))
        #expect(rig.reported.raised)
    }

    /// The session's own line, which the app's log and the CLI's print both read. Where
    /// the words went is read off what was performed, so a route that names its own app
    /// says that app and not the one that happened to be in front at key-down.
    @Test func aSessionsLineNamesTheAppItsRouteTargetedNotTheOneInFront() async throws {
        let safari = BundleID(rawValue: "com.apple.Safari")
        let rig = try Rig(
            transcriber: { FakeTranscriber { _ in Transcript(typed: "a") } },
            router: Router(routes: [Route(when: .always, then: .insertTranscript(target: .app(bundleID: safari)))])
        )
        rig.hold()
        #expect(try await rig.session().description.hasSuffix("1 actions into com.apple.Safari"))
    }

    /// Nothing said is a session that performed nothing, and a destination it never had
    /// is left unsaid rather than rendered as an empty one.
    @Test func aSessionThatPerformedNothingNamesNoDestination() async throws {
        let rig = try Rig(hearing: FakeTranscriber { _ in Transcript(typed: "") })
        rig.hold()
        #expect(try await rig.session().description.hasSuffix("0 actions"))
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
