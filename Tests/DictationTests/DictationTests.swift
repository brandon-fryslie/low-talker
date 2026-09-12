import Dictation
import Foundation
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
    /// Where the fake microphone's clock starts; any moment would do, since a timeline
    /// is measured in differences.
    static let origin = HostTime(uptime: .zero)
    /// The host clock the fake microphone stamps its buffers with. It starts where the
    /// capture's timeline does and advances by the audio the test feeds, so a test can
    /// name the moment a key went down in the middle of speech already spoken.
    private(set) var now = Rig.origin
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
        retaining: TimeInterval = AudioCapture.defaultRetention,
        atRest: MicrophoneAtRest = .shut,
        frontmost: @escaping @Sendable @MainActor () throws -> BundleID = { textEdit }
    ) throws {
        capture = AudioCapture(retaining: retaining, hardware: hardware, startingAt: Self.origin)
        // Shut between presses unless a test says otherwise, which is the loop the app
        // runs when no config file asks for the microphone to be held.
        try capture.start(try MicrophonePermission(authority: Authorized()).current.grant(), atRest: atRest)
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

    convenience init(
        hearing transcriber: FakeTranscriber,
        retaining: TimeInterval = AudioCapture.defaultRetention,
        atRest: MicrophoneAtRest = .shut
    ) throws {
        try self.init(transcriber: { transcriber }, retaining: retaining, atRest: atRest)
    }

    /// Audio captured from `now` on, stamped as the microphone would stamp it, into
    /// whichever engine is running: a replaced one is deaf, as it is on a real Mac.
    func speak(_ samples: [Float]) {
        hardware.live.appending(samples, now)
        now = now + .seconds(AudioClip.duration(for: samples.count))
    }

    /// Time passing with nothing appended: the speaker may be talking, and that is exactly
    /// what nothing is capturing. This is how a test says a key-down reached the loop late:
    /// the stamp is taken before the wait and the press is made after it.
    func wait(_ duration: TimeInterval) {
        now = now + .seconds(duration)
    }

    /// The input device changes: macOS stops the engine and posts the change, and capture
    /// launches a fresh one on the new device. Nothing is captured in between, and the
    /// test's clock does not advance over it either - the gap leaves no samples behind to
    /// be measured by, which is the whole of why it has to be marked when it happens.
    func changeDevice() {
        hardware.readied.onStale()
    }

    /// A hold of the hotkey with `samples` captured during it, the key-down heard the
    /// moment it was made.
    func hold(speaking samples: [Float] = [1, 2, 3]) {
        dictation.press(.began(Self.rightOption, at: now))
        speak(samples)
        dictation.press(.ended(Self.rightOption, .released(.hold)))
    }

    /// A hold that opens no microphone, because something refused the press before one
    /// could open - no app to type into, or no device to record with. Nothing is spoken
    /// into it, which is not the test being coy: there is nothing listening, and that is
    /// the state being described.
    func refusedHold() {
        dictation.press(.began(Self.rightOption, at: now))
        dictation.press(.ended(Self.rightOption, .released(.hold)))
    }

    /// The same hold, ended by the tap going deaf rather than by the speaker letting
    /// go: everything up to here was captured, and what came after it was not.
    func lapse(speaking samples: [Float] = [1, 2, 3]) {
        dictation.press(.began(Self.rightOption, at: now))
        speak(samples)
        dictation.press(.ended(Self.rightOption, .lapsed))
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

    /// The audio is what the ring held between the marks, and the microphone opens for
    /// the press, so there is nothing in front of them: the pre-roll reaches back over the
    /// moment the engine started and stops there. A press hears what was said into it and
    /// never the tail of the press before it - those words were said a minute ago, and a
    /// clip that began with them would transcribe to a sentence nobody just spoke.
    @Test func aPressHearsWhatWasSaidIntoItAndNotThePressBeforeIt() async throws {
        let engine = FakeTranscriber { _ in Transcript(typed: "") }
        let rig = try Rig(hearing: engine)
        rig.hold(speaking: [1, 2])
        _ = try await rig.session()
        rig.hold(speaking: [7, 8])
        _ = try await rig.session()
        #expect(engine.clips.map(\.samples) == [[1, 2], [7, 8]])
    }

    /// The other side of that trade, driven through the same loop: a microphone the resting
    /// mode has held open since `start()` has audio behind the key, so a press made a word
    /// into a sentence carries the word it was pressed a moment too late for. The test above
    /// pins what `shut` gives the indicator up for; this one pins what `open` buys back.
    @Test func aPressMadeWhileTheMicrophoneIsHeldOpenHearsTheWordsBeforeIt() async throws {
        let engine = FakeTranscriber { _ in Transcript(typed: "") }
        let rig = try Rig(hearing: engine, atRest: .open)
        rig.speak([1, 2])
        rig.hold(speaking: [7, 8])
        _ = try await rig.session()
        #expect(engine.clips.map(\.samples) == [[1, 2, 7, 8]])
    }

    /// The mark still comes from the key event's own stamp rather than from the moment
    /// the handler ran, and what that buys has changed with the microphone's lifetime:
    /// there is no audio behind an engine that has just started for the mark to reach
    /// into, so the stamp's remaining job is the other half - keeping a key-down stamped
    /// back among an earlier press's samples from beginning this press among them.
    @Test func aKeyDownDeliveredLateDoesNotReachIntoThePressBeforeIt() async throws {
        let engine = FakeTranscriber { _ in Transcript(typed: "") }
        let rig = try Rig(hearing: engine)
        let duringTheFirstPress = rig.now
        rig.hold(speaking: [1, 2, 3])
        _ = try await rig.session()

        rig.dictation.press(.began(Rig.rightOption, at: duringTheFirstPress))
        rig.speak([4, 5])
        rig.dictation.press(.ended(Rig.rightOption, .released(.hold)))
        _ = try await rig.session()
        #expect(engine.clips.map(\.samples) == [[1, 2, 3], [4, 5]])
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

    /// [LAW:no-silent-failure] The key-down reached the loop long after the key went down,
    /// and the microphone opens when the loop hears it: the speaker had been talking for
    /// 0.4 s to a microphone that was shut, and no engine can be started in the past. What
    /// is left is the back of an utterance, and nothing in those samples or in the text
    /// they transcribe to says the front is missing - which is the whole reason the press
    /// says it rather than typing it.
    ///
    /// This is the cost the epic traded the look-back for, and the door it has to leave by.
    /// Under continuous capture the pre-roll covered a late key-down by reaching back over
    /// audio already on the ring; with the microphone opening per press there is nothing
    /// behind the mark to reach into, so a loss that used to be repaired is now reported.
    @Test func aPressWhoseMicrophoneOpenedAfterTheWordsItWasPressedForIsReportedNotTyped() async throws {
        let engine = FakeTranscriber { _ in Transcript(typed: "a") }
        let rig = try Rig(hearing: engine)

        let keyWentDown = rig.now
        // The speaker starts talking as they press. The loop hears the press 0.4 s later -
        // well past the warm-up an engine is allowed - so none of those words was captured.
        rig.wait(0.4)
        rig.dictation.press(.began(Rig.rightOption, at: keyWentDown))
        rig.speak([1, 2, 3])
        rig.dictation.press(.ended(Rig.rightOption, .released(.hold)))

        let press = try #require(await rig.report().failure as? SpeechLost)
        #expect(press.chord == Rig.rightOption)
        #expect(press.lost.unopened)
        #expect(!press.lost.interrupted)
        #expect(press.lost.scrolledOff == 0)
        #expect(engine.clips.isEmpty)
        #expect(rig.keyboard.log.isEmpty)

        // The next press is heard the moment it is made, so its microphone is open for all
        // of it and it types.
        rig.hold(speaking: [4, 5])
        #expect(try await rig.session().transcript.text == "a")
        #expect(engine.clips.map(\.samples) == [[4, 5]])
        #expect(rig.keyboard.log == Self.typed("a"))
    }

    /// The epic's contract, as one run: speech spoken into a press appears in that
    /// press's clip, whatever the loop is doing at the time. [LAW:behavior-not-structure]
    /// It asserts the audio each session was given and the text each one typed - not
    /// which actor ran what, which is how the loop keeps the promise and not the promise.
    ///
    /// The run is the one that was reported from live use: a press says a sentence, and
    /// while that sentence is still being typed the speaker starts the next utterance and
    /// presses the key again. The insert is held at its first keystroke, where a real one
    /// waits for the device to answer - the epic measured about 29 ms a key, so these 43
    /// characters hold it well over a second. Held at a gate rather than for a duration:
    /// a loop that only kept its words when the machine typed fast enough would be the
    /// same bug wearing a stopwatch. [LAW:no-ambient-temporal-coupling]
    ///
    /// What the second press needs is for its key-down to be handled while the insert is
    /// still running, because that is where the microphone opens now: a key-down queued
    /// behind the typing would open the microphone after the words it was pressed for had
    /// been said, and the clip would show it. Every sample of the second utterance is in
    /// the second clip and none of the first is, which is both halves of the promise.
    @Test func everyWordSpokenIntoAPressMadeDuringAnInsertIsInThatPressesClip() async throws {
        let gate = Gate()
        let sentence = "the quick brown fox jumps over the lazy dog"
        // Each press is spoken in a sample value of its own, so a clip says which press's
        // words it is holding and speech that landed in the wrong one cannot pass for the
        // right one. Nothing is spoken between them: the microphone is shut there, and a
        // test that fed it would be describing a Mac that does not exist.
        let said = [Float](repeating: 1, count: AudioClip.sampleCount(for: 0.5))
        let andThen = [Float](repeating: 2, count: AudioClip.sampleCount(for: 0.8))
        let engine = FakeTranscriber { clip in Transcript(typed: clip.samples.contains(1) ? sentence : "b") }
        let rig = try Rig(hearing: engine)
        rig.keyboard.acknowledgement = { await gate.wait() }
        let insert = sentence.flatMap(Self.typed)

        rig.hold(speaking: said)
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { gate.waiting == 1 })
        #expect(rig.keyboard.log == Array(insert.prefix(2)))

        rig.hold(speaking: andThen)
        #expect(rig.keyboard.log == Array(insert.prefix(2)))

        gate.open()
        #expect(try await rig.session().transcript.text == sentence)
        #expect(try await rig.session().transcript.text == "b")
        #expect(engine.clips.map(\.samples) == [said, andThen])
        #expect(rig.keyboard.log == insert + Self.typed("b"))
    }

    @Test func aPressWithNothingToTypeIntoIsReportedAndTheNextPressTypes() async throws {
        let refused = Mutex(true)
        let rig = try Rig(transcriber: { FakeTranscriber { _ in Transcript(typed: "a") } }) {
            if refused.withLock({ $0 }) { throw NoApp() }
            return Rig.textEdit
        }
        rig.refusedHold()
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
        rig.refusedHold()
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

    /// [LAW:no-silent-failure] Two presses the speaker made identically, told apart by
    /// nothing but how listening stopped. The tap goes deaf partway through the first,
    /// so what it captured runs to the lapse and not to the release: it is reported as
    /// lapsed and never reaches the engine, because a fragment typed into the user's
    /// editor arrives unmarked as a fragment and cannot be marked there. The second is
    /// released and types. The outcomes have nothing in common, which is the whole of
    /// what the ending buys.
    @Test func aPressTheTapLapsedOutOfIsReportedInsteadOfTypedAndTheNextPressTypes() async throws {
        let engine = FakeTranscriber { _ in Transcript(typed: "a") }
        let rig = try Rig(hearing: engine)

        rig.lapse(speaking: [1, 2, 3])
        let lapsed = try #require(await rig.report().failure as? PressLapsed)
        #expect(lapsed.chord == Rig.rightOption)
        #expect(engine.clips.isEmpty)
        #expect(rig.keyboard.log.isEmpty)

        rig.hold(speaking: [1, 2, 3])
        #expect(try await rig.session().transcript.text == "a")
        #expect(engine.clips.count == 1)
        #expect(rig.keyboard.log == Self.typed("a"))
    }

    /// [LAW:no-silent-failure] The speaker held the key for longer than the ring retains,
    /// so the first of what they said was overwritten by the last of it before the key
    /// came up. What is left is a plausible utterance: nothing in the samples says where
    /// it was cut, and - as the epic's contract test found by losing 0.4 s of speech with
    /// every assertion over typed text still passing - nothing in the text says it either.
    /// So the press is reported rather than typed, the same answer a lapsed press gets and
    /// for the same reason: the destination is the user's editor, where a fragment cannot
    /// be marked as one. The loss is named in samples, which is what makes this an
    /// assertion and not a hope. [LAW:behavior-not-structure]
    @Test func aPressTheRingCouldNotHoldWholeIsReportedInsteadOfTypedAndTheNextPressTypes() async throws {
        let engine = FakeTranscriber { _ in Transcript(typed: "a") }
        let rig = try Rig(hearing: engine, retaining: 0.5)

        rig.hold(speaking: [Float](repeating: 1, count: AudioClip.sampleCount(for: 0.8)))
        let press = try #require(await rig.report().failure as? SpeechLost)
        #expect(press.chord == Rig.rightOption)
        // A 0.8 s hold into a ring that keeps 0.5 s: the missing 0.3 s is the head of the
        // utterance, and the pre-roll reaching back before the microphone started is not
        // part of it - there was no audio there to lose.
        #expect(press.lost.scrolledOff == AudioClip.sampleCount(for: 0.3))
        #expect(!press.lost.interrupted)
        #expect(engine.clips.isEmpty)
        #expect(rig.keyboard.log.isEmpty)

        rig.hold(speaking: [2, 3])
        #expect(try await rig.session().transcript.text == "a")
        #expect(engine.clips.count == 1)
        #expect(rig.keyboard.log == Self.typed("a"))
    }

    /// [LAW:no-silent-failure] The input device changed in the middle of a press - AirPods
    /// connecting mid-sentence, the everyday case. macOS stops the engine and capture
    /// launches a new one on the new device, and the speech in between is not captured by
    /// either. What the ring holds is the words before the change butted straight against
    /// the words after it, with nothing in the samples marking the join: ring positions
    /// advance only on capture, so the stretch that was lost left nothing behind, not even
    /// a hole. The press is reported instead of typed, because what a splice transcribes
    /// to is a sentence - just not the one that was said.
    @Test func aPressTheInputDeviceChangedDuringIsReportedInsteadOfTyped() async throws {
        let engine = FakeTranscriber { _ in Transcript(typed: "a") }
        let rig = try Rig(hearing: engine)

        rig.dictation.press(.began(Rig.rightOption, at: rig.now))
        rig.speak([1, 2])
        rig.changeDevice()
        rig.speak([3, 4])
        rig.dictation.press(.ended(Rig.rightOption, .released(.hold)))

        let press = try #require(await rig.report().failure as? SpeechLost)
        #expect(press.chord == Rig.rightOption)
        #expect(press.lost.interrupted)
        #expect(press.lost.scrolledOff == 0)
        #expect(engine.clips.isEmpty)
        #expect(rig.keyboard.log.isEmpty)

        // The next press is whole: it opens a microphone of its own and reaches back over
        // nothing, so the seam is behind it however close to it the key went down.
        rig.hold(speaking: [5, 6])
        #expect(try await rig.session().transcript.text == "a")
        #expect(engine.clips.map(\.samples) == [[5, 6]])
    }

    /// A device change that really took time is still only a splice: the head of the press
    /// was captured, so what it lost is its middle and nothing else.
    ///
    /// The reconnect is what the other splice tests leave out. They stamp the audio either
    /// side of the change as if no time passed, and a press that loses a third of a second
    /// to AirPods is the everyday shape of one. The distinction matters because the two
    /// losses are different sentences: this press is spliced, and telling its speaker the
    /// microphone was not open for it would be false - it was open, on time, and heard the
    /// first word.
    @Test func aPressSplicedAcrossARealReconnectIsNotAlsoReportedAsUnopened() async throws {
        let engine = FakeTranscriber { _ in Transcript(typed: "a") }
        let rig = try Rig(hearing: engine)

        rig.dictation.press(.began(Rig.rightOption, at: rig.now))
        rig.speak([1, 2])
        rig.changeDevice()
        // The outage itself: real time in which no engine is running, so nothing is
        // captured over it and the positions either side of it are adjacent.
        rig.wait(0.3)
        rig.speak([3, 4])
        rig.dictation.press(.ended(Rig.rightOption, .released(.hold)))

        let press = try #require(await rig.report().failure as? SpeechLost)
        #expect(press.lost.interrupted)
        #expect(!press.lost.unopened)
        #expect(press.lost.scrolledOff == 0)
        #expect(press.lost.description == "spliced where capture restarted")
    }

    /// [LAW:no-silent-failure] There is no microphone to open - the device cannot feed the
    /// pipeline - so the press is refused at the key and reported. A loop that carried on
    /// would hand the engine the empty clip a shut microphone leaves behind, and an empty
    /// clip transcribes exactly like a quiet room.
    ///
    /// The press is made without speaking into it, because there is nothing to speak into:
    /// with the microphone opening per press, a capture with no working device has no
    /// engine at all rather than a failed one.
    @Test func aPressWithNoMicrophoneToOpenIsReportedNotHeardAsSilence() async throws {
        let engine = FakeTranscriber { _ in Transcript(typed: "a") }
        let rig = try Rig(hearing: engine)
        rig.hardware.failingToLaunch = BadBuffer()
        rig.refusedHold()
        let failure = try #require(await rig.report().failure as? NoMicrophone)
        guard case .failed(let error) = failure else { Issue.record("expected the capture's failure, got \(failure)"); return }
        #expect(error is BadBuffer)
        #expect(engine.clips.isEmpty)

        // The device comes back, and the next press opens a microphone and types.
        rig.hardware.failingToLaunch = nil
        rig.hold(speaking: [1, 2])
        #expect(try await rig.session().transcript.text == "a")
        #expect(rig.keyboard.log == Self.typed("a"))
    }

    /// [LAW:no-silent-failure] The engine failed under an open press - a driver going down
    /// mid-sentence, with no device change and nothing to recover onto before the key came
    /// up. The microphone was gone for the tail of the press, so what the ring holds ends
    /// somewhere inside the sentence, and a fragment that transcribes fluently is the one
    /// thing that must not be typed.
    ///
    /// This is the door the loop's own `.stopped`/`.failed` branches used to hold open.
    /// They are gone: a press that lost its microphone is reported because its audio comes
    /// back partial, the same as any other loss, so the report rests entirely on capture
    /// marking it - which is what this press checks.
    @Test func aPressWhoseMicrophoneFailedMidHoldIsReportedInsteadOfTyped() async throws {
        let engine = FakeTranscriber { _ in Transcript(typed: "a") }
        let rig = try Rig(hearing: engine)

        rig.dictation.press(.began(Rig.rightOption, at: rig.now))
        rig.speak([1, 2])
        rig.hardware.live.onFailure(BadBuffer())
        rig.dictation.press(.ended(Rig.rightOption, .released(.hold)))

        let press = try #require(await rig.report().failure as? SpeechLost)
        #expect(press.chord == Rig.rightOption)
        #expect(press.lost.unopened)
        #expect(!press.lost.interrupted)
        #expect(engine.clips.isEmpty)
        #expect(rig.keyboard.log.isEmpty)

        // The failed engine was let go with the press, so the next one opens a microphone
        // of its own rather than finding capture wedged on the engine that died.
        rig.hold(speaking: [3, 4])
        #expect(try await rig.session().transcript.text == "a")
        #expect(rig.keyboard.log == Self.typed("a"))
    }
}
