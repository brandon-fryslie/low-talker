import AVFoundation
import LowTalkerCore
import Testing

private struct NoDevice: Error, Equatable {}
private struct BadBuffer: Error, Equatable {}

/// Hardware a test controls: each launch takes the next scripted outcome, every
/// engine's callbacks are the test's to fire, and the default input device changes
/// when the test says so.
@MainActor
private final class FakeHardware: AudioHardware {
    final class Engine {
        let appending: @Sendable ([Float], HostTime) -> Void
        let onFailure: @MainActor (any Error) -> Void
        let onConfigurationChange: @MainActor () -> Void
        var disposed = false

        init(appending: @escaping @Sendable ([Float], HostTime) -> Void, onFailure: @escaping @MainActor (any Error) -> Void, onConfigurationChange: @escaping @MainActor () -> Void) {
            self.appending = appending
            self.onFailure = onFailure
            self.onConfigurationChange = onConfigurationChange
        }
    }

    /// What each launch does, in order: an error to throw, or nil to succeed. A launch
    /// past the end of the script succeeds.
    private var launches: [(any Error)?]
    /// What `watchDefaultInput` does: an error to throw, or nil to watch.
    private let watch: (any Error)?
    private(set) var engines: [Engine] = []
    private var onDefaultInputChange: (@MainActor () -> Void)?
    private(set) var watchDisposals = 0

    init(launches: [(any Error)?] = [], watch: (any Error)? = nil) {
        self.launches = launches
        self.watch = watch
    }

    func launch(appending: @escaping @Sendable ([Float], HostTime) -> Void, onFailure: @escaping @MainActor (any Error) -> Void, onConfigurationChange: @escaping @MainActor () -> Void) throws -> Disposal {
        if let error = launches.isEmpty ? nil : launches.removeFirst() { throw error }
        let engine = Engine(appending: appending, onFailure: onFailure, onConfigurationChange: onConfigurationChange)
        engines.append(engine)
        return { engine.disposed = true }
    }

    func watchDefaultInput(_ onChange: @escaping @MainActor () -> Void) throws -> Disposal {
        if let watch { throw watch }
        onDefaultInputChange = onChange
        return { [self] in
            onDefaultInputChange = nil
            watchDisposals += 1
        }
    }

    var isWatching: Bool { onDefaultInputChange != nil }

    /// The system default input device changed.
    func changeDefaultInput() throws {
        let onChange = try #require(onDefaultInputChange, "nothing is watching the default input")
        onChange()
    }
}

private struct Authorized: MicrophoneAuthority {
    func status() -> AVAuthorizationStatus { .authorized }
    func requestAccess() async -> Bool { true }
}

@MainActor
@Suite struct AudioCaptureTests {
    private let grant = try! MicrophonePermission(authority: Authorized()).current.grant()
    /// Where every capture in this suite starts its timeline; any moment would do.
    private let origin = HostTime(uptime: .zero)

    /// The moment the sample at position `count` is captured, at the pipeline rate.
    private func after(_ count: Int) -> HostTime { origin + .seconds(AudioClip.duration(for: count)) }

    private func isRunning(_ capture: AudioCapture) -> Bool {
        if case .running = capture.state { return true }
        return false
    }

    private func isListening(_ capture: AudioCapture) -> Bool {
        if case .listening = capture.state { return true }
        return false
    }

    private func failure<E: Error & Equatable>(of capture: AudioCapture, as: E.Type) -> E? {
        if case .failed(let error) = capture.state { return error as? E }
        return nil
    }

    /// The loss a partial capture is expected to carry. A `Loss` refuses to be nothing,
    /// so an expectation of one is spelled out here and the test reads as an equality.
    private func loss(scrolledOff: Int = 0, interrupted: Bool = false, unopened: Bool = false) throws -> CapturedAudio.Loss {
        try #require(CapturedAudio.Loss(scrolledOff: scrolledOff, interrupted: interrupted, unopened: unopened))
    }

    /// A capture that is started and listening, with a session open on it. Shut at rest
    /// unless a test says otherwise, which is how the app runs when no config file asks
    /// for anything else. Every test that needs audio needs one.
    private func opened(_ capture: AudioCapture, atRest: MicrophoneAtRest = .shut, at moment: HostTime? = nil, preRoll: TimeInterval = 0) throws -> AudioSession {
        try capture.start(grant, atRest: atRest)
        return try capture.beginSession(at: moment ?? origin, preRoll: preRoll)
    }

    /// The whole point of the epic, and the default a Mac with no config file gets: a
    /// started capture holds the grant and watches the input device, and opens no
    /// microphone at all. macOS shows a microphone for an engine that is running, so an app
    /// that starts one at launch is an app the menu bar says is listening all day.
    @Test func startOpensNoMicrophoneAndWatchesTheDefaultInput() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware)
        try capture.start(grant, atRest: .shut)
        #expect(isListening(capture))
        #expect(hardware.engines.isEmpty)
        #expect(hardware.isWatching)
    }

    @Test func beginningASessionOpensTheMicrophoneAndEndingItShutsIt() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try opened(capture)
        #expect(isRunning(capture))
        #expect(hardware.engines.count == 1)
        hardware.engines[0].appending([1, 2, 3], origin)
        _ = capture.endSession(session)
        #expect(isListening(capture))
        #expect(hardware.engines[0].disposed)
    }

    /// Press after press, each opens its own engine and gives it back. The ring is the
    /// one thing that carries across.
    @Test func eachSessionGetsItsOwnEngine() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let first = try opened(capture)
        hardware.engines[0].appending([1, 2], origin)
        #expect(capture.endSession(first) == .whole(AudioClip(samples: [1, 2])))

        let second = try capture.beginSession(at: after(2), preRoll: 0)
        #expect(hardware.engines.count == 2)
        hardware.engines[1].appending([3, 4], after(2))
        #expect(capture.endSession(second) == .whole(AudioClip(samples: [3, 4])))
        #expect(hardware.engines[1].disposed)
    }

    @Test func whatTheEngineCapturesIsWhatTheRingHolds() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try opened(capture)
        hardware.engines[0].appending([1, 2, 3], origin)
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2, 3])))
    }

    /// A session begins where the microphone opened, however early the key it came from
    /// was stamped. The mark is still taken from the event's own moment - the pre-roll is
    /// what covers a key pressed after speech began, and reaching back is that mark's job
    /// while an engine is already running - but an engine opened for this session has
    /// captured nothing for the mark to reach into, so it lands on the position its first
    /// sample will take. That is the whole of what a per-press microphone costs, and it
    /// is here rather than hidden in an empty clip.
    @Test func aSessionBeginsWhereTheMicrophoneOpenedHoweverEarlyTheKeyWas() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let first = try opened(capture)
        hardware.engines[0].appending([1, 2, 3, 4], origin)
        _ = capture.endSession(first)

        // A key stamped back among the first session's samples, which is as far back as a
        // late-delivered key-down could ever point.
        let session = try capture.beginSession(at: after(1), preRoll: 0)
        #expect(session.begin == 4)
        hardware.engines[1].appending([5, 6], after(4))
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [5, 6])))
    }

    /// The key went down between two buffers, so the moment is later than anything
    /// captured. A session cannot begin in audio that does not exist yet: it begins at
    /// the newest sample and holds what comes after. With the microphone opening for the
    /// session this is every session - an engine that has just started has captured
    /// nothing, so the mark lands on the position its first sample will take.
    @Test func aSessionBegunAfterTheNewestSampleBeginsAtTheNewestSample() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try opened(capture, at: after(9))
        hardware.engines[0].appending([3], after(2))
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [3])))
    }

    /// A hold longer than the ring retains: the first of what was said was overwritten by
    /// the last of it before the key came up. What comes back is the tail, and it says how
    /// much of the head is gone rather than passing for the whole utterance.
    @Test func aSessionWhoseHeadTheRingDroppedSaysHowMuchIsGone() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(retaining: AudioClip.duration(for: 4), hardware: hardware, startingAt: origin)
        let session = try opened(capture)
        hardware.engines[0].appending([1, 2, 3, 4, 5, 6], origin)
        #expect(try capture.endSession(session) == .partial(AudioClip(samples: [3, 4, 5, 6]), lost: loss(scrolledOff: 2)))
    }

    /// A press that opens its own microphone has nothing to reach back over: the pre-roll
    /// clamps to the moment the engine started, and audio that was never captured was not
    /// lost. This is the ordinary state of every press once the microphone opens per
    /// session, and it is what the epic traded the look-back for.
    @Test func aPreRollHasNothingToReachBackOverWhenTheMicrophoneJustOpened() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try opened(capture, preRoll: AudioSession.defaultPreRoll)
        #expect(session.preRoll == 0)
        hardware.engines[0].appending([1, 2], origin)
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2])))
    }

    /// The pre-roll never reaches across the moment the microphone opened, so a press
    /// cannot pick up the tail of the press before it: those words were said a minute ago
    /// and belong to no part of this utterance.
    @Test func aPreRollDoesNotReachIntoAnEarlierSessionsAudio() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let first = try opened(capture)
        hardware.engines[0].appending([1, 2, 3, 4], origin)
        _ = capture.endSession(first)

        let second = try capture.beginSession(at: after(4), preRoll: AudioSession.defaultPreRoll)
        #expect(second.preRoll == 0)
        hardware.engines[1].appending([5, 6], after(4))
        #expect(capture.endSession(second) == .whole(AudioClip(samples: [5, 6])))
    }

    // MARK: - the microphone held at rest

    /// The other side of the epic's trade, and the only thing that can make this app hold
    /// the device while nobody is dictating. macOS lights the menu bar for as long as the
    /// engine runs, so a test that let this pass on a config nobody wrote would be a test
    /// that let the whole epic be undone by a default.
    @Test func theMicrophoneIsHeldFromTheStartWhenTheConfigAsksForIt() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try capture.start(grant, atRest: .open)
        #expect(hardware.engines.count == 1)
        #expect(!hardware.engines[0].disposed)
        // Nobody is holding the key, so nothing is being dictated: the microphone is open
        // on the user's own arrangement rather than for a press.
        #expect(isListening(capture))
    }

    /// What the mode buys, stated as the difference it makes to a press. Compare
    /// `aPreRollHasNothingToReachBackOverWhenTheMicrophoneJustOpened`, where the same
    /// pre-roll over the same press comes back with nothing in front of it: there, the
    /// microphone opened at the key and there was no audio behind it to reach into.
    @Test func aHeldMicrophoneGivesAPressTheLookBackAPerPressOneCannotHave() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try capture.start(grant, atRest: .open)
        // Said before the key went down: the speaker began the word and then reached for
        // the chord.
        hardware.engines[0].appending([1, 2], origin)
        let session = try capture.beginSession(at: after(2), preRoll: AudioSession.defaultPreRoll)
        #expect(session.preRoll == 2)
        hardware.engines[0].appending([3, 4], after(2))
        // One engine throughout, so there is no splice between the two halves of the word
        // and the ring behind the key is this session's to reach into.
        #expect(hardware.engines.count == 1)
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2, 3, 4])))
    }

    /// The key-up does not close a microphone the user asked to have held, and does not
    /// relaunch it either: a relaunch would splice the ring at every release, which is the
    /// look-back being thrown away once per press by the mode that exists to keep it.
    @Test func aHeldMicrophoneOutlivesThePressThatSpokeIntoIt() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try capture.start(grant, atRest: .open)
        let first = try capture.beginSession(at: origin, preRoll: 0)
        hardware.engines[0].appending([1, 2], origin)
        #expect(capture.endSession(first) == .whole(AudioClip(samples: [1, 2])))
        #expect(hardware.engines.count == 1)
        #expect(!hardware.engines[0].disposed)
        #expect(isListening(capture))

        let second = try capture.beginSession(at: after(2), preRoll: 0)
        hardware.engines[0].appending([3, 4], after(2))
        #expect(capture.endSession(second) == .whole(AudioClip(samples: [3, 4])))
        #expect(hardware.engines.count == 1)
    }

    /// A key-down the tap delivered late is the press `unopened` exists to catch, and it is
    /// not one here. A held engine's buffers run continuously, so the next one to arrive
    /// after the key was already being captured when the key went down - its stamp is a
    /// full second older than the press - and the words said during that lateness are in
    /// the ring rather than missing from it. This is a press a per-press microphone reports
    /// cut and a held one reports whole, and both are right about their own machine.
    @Test func aPressOnAHeldMicrophoneIsNotChargedForAHeadItHeard() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try capture.start(grant, atRest: .open)
        let late = after(AudioClip.sampleCount(for: 1))
        let session = try capture.beginSession(at: late, preRoll: 0)
        hardware.engines[0].appending([1, 2], origin)
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2])))
    }

    /// The door that a held microphone must not close. A microphone open for hours is one
    /// that can die quietly and go on looking open, and a press it delivers nothing for
    /// yields an empty clip - which transcribes to nothing at all, and reads exactly like a
    /// quiet room. Nothing about being held makes that press whole.
    /// [LAW:no-silent-failure]
    @Test func aHeldMicrophoneThatDeliveredNothingForAPressStillSaysItWasNotOpen() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try capture.start(grant, atRest: .open)
        hardware.engines[0].appending([1, 2], origin)
        let session = try capture.beginSession(at: after(2), preRoll: 0)
        #expect(try capture.endSession(session) == .partial(AudioClip(samples: []), lost: loss(unopened: true)))
    }

    /// The device was gone when capture started, so there was nothing to hold. A press is
    /// a reason to try the device again; without that, a Mac that booted with its
    /// microphone unplugged would stay deaf until one was plugged in, even with a key held
    /// down. [LAW:no-silent-failure]
    @Test func aHeldMicrophoneThatCouldNotOpenIsTriedAgainByTheNextPress() throws {
        let hardware = FakeHardware(launches: [NoDevice()])
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try capture.start(grant, atRest: .open)
        #expect(failure(of: capture, as: NoDevice.self) == NoDevice())
        #expect(hardware.engines.isEmpty)

        let session = try capture.beginSession(at: origin, preRoll: 0)
        #expect(hardware.engines.count == 1)
        // The device did come back, and a press is simply where that was noticed: the gap
        // it ends is booked the same as one the device watch ends, or the count would
        // depend on which of the two got there first. [LAW:single-enforcer]
        #expect(capture.outages.count == 1)
        #expect(capture.outages.total > .zero)
        hardware.engines[0].appending([1, 2], origin)
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2])))
    }

    /// The press tried the device and the device is still gone. What the user is owed then
    /// is the reason it is dead *now* - a microphone unplugged an hour ago and a cable that
    /// has just failed are the same silence, and only the newest error tells them apart. No
    /// gap is booked, because none ended: this retry extends the outage it found.
    /// [LAW:no-silent-failure]
    @Test func aPressThatCannotReviveAHeldMicrophoneLeavesItFailedAndCountsNoGap() throws {
        let hardware = FakeHardware(launches: [NoDevice(), BadBuffer()])
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try capture.start(grant, atRest: .open)
        #expect(failure(of: capture, as: NoDevice.self) == NoDevice())

        #expect(throws: NoMicrophone.self) { try capture.beginSession(at: origin, preRoll: 0) }
        #expect(failure(of: capture, as: BadBuffer.self) == BadBuffer())
        #expect(hardware.engines.isEmpty)
        #expect(capture.outages.count == 0)
    }

    /// Device churn while nobody is dictating, which only a held microphone can meet: the
    /// engine runs for hours, so a docking station waking up replaces it with no press in
    /// flight. The press that follows hears the new device only, and the audio the old one
    /// captured is on the far side of a splice - so the look-back this mode is held open
    /// for stops at the new engine's first sample rather than reaching across the break
    /// into a clip whose seam is in no sample.
    @Test func aDeviceChangedWhileIdleIsReplacedAndTheNextPressIsWhole() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try capture.start(grant, atRest: .open)
        hardware.engines[0].appending([1, 2, 3, 4, 5, 6], origin)

        hardware.engines[0].onConfigurationChange()
        #expect(hardware.engines[0].disposed)
        #expect(hardware.engines.count == 2)
        #expect(capture.deviceChanges == 1)
        // A swap is not an outage and not a press: nothing failed, and nobody is dictating.
        #expect(capture.outages.count == 0)
        #expect(isListening(capture))

        // A second of pre-roll, against a key stamped back among the old device's samples:
        // both reach for audio this run of capture no longer continues from.
        let session = try capture.beginSession(at: after(1), preRoll: 1)
        #expect(session.preRoll == 0)
        hardware.engines[1].appending([7, 8], after(6))
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [7, 8])))
    }

    /// Quitting gives the device back, however the run was holding it.
    @Test func stopGivesUpAHeldMicrophone() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try capture.start(grant, atRest: .open)
        capture.stop()
        #expect(hardware.engines[0].disposed)
        #expect(hardware.watchDisposals == 1)
        if case .stopped = capture.state {} else { Issue.record("stop did not stop") }
    }

    /// The menu reads this rather than the config it was started from, so what it tells the
    /// user is what their microphone is doing. A run that never started says nothing, which
    /// is the truth and is not the same answer as "shut between presses".
    @Test func theRestingModeIsReadBackFromTheRunOfCaptureHoldingIt() throws {
        let capture = AudioCapture(hardware: FakeHardware(), startingAt: origin)
        #expect(capture.atRest == nil)
        try capture.start(grant, atRest: .open)
        #expect(capture.atRest == .open)
        capture.stop()
        #expect(capture.atRest == nil)
    }

    /// The resting mode is what the user asked for; this is what they got, and under `open`
    /// they are the two things most likely to disagree. An engine held across presses can
    /// die while nobody is pressing anything, and nothing will try the device again until
    /// someone does - so for as long as that takes, a status surface reading the mode alone
    /// reports a live microphone on a Mac that has none. This is the one reading that puts
    /// the failure in front of the user before their next press does.
    /// [LAW:no-silent-failure]
    @Test func aHeldMicrophoneThatDiedSaysSoRatherThanThatItIsStillHeldOpen() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        // Not started is its own answer, and not the same one as "shut between presses".
        #expect(capture.doing == "not being captured")

        try capture.start(grant, atRest: .open)
        #expect(capture.doing == "\(MicrophoneAtRest.open)")

        hardware.engines[0].onFailure(NoDevice())
        let dead = capture.doing
        #expect(dead != "\(MicrophoneAtRest.open)")
        // Still says which mode the run is in - the user's arrangement did not change - and
        // now says the device is not keeping to it, in the failure's own words.
        #expect(dead.contains("\(MicrophoneAtRest.open)"))
        #expect(dead.contains("\(NoDevice())"))
    }

    // MARK: - what a press was missing

    /// The engine took longer to start than the key was held, so not one sample of what
    /// was said was captured. An empty clip transcribes to nothing at all, which reads
    /// exactly like a quiet room; this is the door that tells the two apart.
    @Test func aSessionTheMicrophoneCapturedNothingForSaysItWasNotOpen() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try opened(capture)
        #expect(try capture.endSession(session) == .partial(AudioClip(samples: []), lost: loss(unopened: true)))
    }

    /// The microphone opened long after the key went down - the key-down reached the
    /// handler late, or this is the first press in the process and the engine paid the
    /// 240-280 ms the first launch costs. Either way the speaker was talking to a shut
    /// microphone, and the clip that comes back is their sentence with the front of it
    /// gone. Nothing in those samples says so, which is why the session does.
    @Test func aSessionWhoseMicrophoneOpenedLongAfterTheKeyWentDownSaysSo() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try opened(capture)
        // The first sample this engine captured was taken 0.4 s after the key went down,
        // so that much of what was said was never captured at all.
        hardware.engines[0].appending([1, 2], after(AudioClip.sampleCount(for: 0.4)))
        #expect(try capture.endSession(session) == .partial(AudioClip(samples: [1, 2]), lost: loss(unopened: true)))
    }

    /// The ordinary press, and the reason the allowance exists at all: an engine is never
    /// instant, so every session's first sample is taken a little after the key went down.
    /// A press that lost only that much is whole - the measurement behind the allowance is
    /// that a speaker has not begun the word yet - and a loop that called this one partial
    /// would refuse every press ever made.
    @Test func aSessionWhoseMicrophoneOpenedWithinTheAllowanceIsWhole() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try opened(capture)
        let warmUp = AudioClip.sampleCount(for: AudioCapture.warmUpAllowance / 2)
        hardware.engines[0].appending([1, 2], after(warmUp))
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2])))
    }

    /// The microphone was open and then was not, and the key came up while it was gone:
    /// the tail of the utterance was never captured, and the clip that is left is a
    /// fragment however complete it looks.
    @Test func aSessionWhoseMicrophoneDiedAndDidNotComeBackIsPartial() throws {
        let hardware = FakeHardware(launches: [nil, NoDevice()])
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try opened(capture)
        hardware.engines[0].appending([1, 2], origin)
        hardware.engines[0].onConfigurationChange()
        #expect(failure(of: capture, as: NoDevice.self) == NoDevice())
        #expect(try capture.endSession(session) == .partial(AudioClip(samples: [1, 2]), lost: loss(unopened: true)))
        #expect(isListening(capture))
    }

    /// A press with no capture behind it is refused at the key, not handed an empty clip
    /// for a transcriber to call a quiet room.
    @Test func beginningASessionOnStoppedCaptureThrows() throws {
        let capture = AudioCapture(hardware: FakeHardware())
        #expect(throws: NoMicrophone.self) { try capture.beginSession(at: origin) }
    }

    /// The device cannot feed the pipeline, so there is no microphone to open and the
    /// press says so. Nothing is left half-open behind it.
    @Test func beginningASessionTheDeviceRefusesThrowsAndLeavesNothingOpen() throws {
        let hardware = FakeHardware(launches: [NoDevice()])
        let capture = AudioCapture(hardware: hardware)
        try capture.start(grant, atRest: .shut)
        #expect(throws: NoMicrophone.self) { try capture.beginSession(at: origin) }
        #expect(isListening(capture))
        #expect(hardware.engines.isEmpty)
        #expect(hardware.isWatching)
    }

    /// The ring survives the engine: samples from before the change are still there
    /// after it, followed by the new engine's - spliced, since nothing was captured in
    /// between and no position advanced while nothing was. A session open across the
    /// change is told so; the samples themselves have no seam to find it by.
    @Test func aConfigurationChangeReplacesTheEngineAndSplicesTheRing() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try opened(capture)
        hardware.engines[0].appending([1], origin)
        hardware.engines[0].onConfigurationChange()
        #expect(hardware.engines[0].disposed)
        #expect(hardware.engines.count == 2)
        #expect(capture.deviceChanges == 1)
        #expect(isRunning(capture))
        hardware.engines[1].appending([2], after(1))
        #expect(try capture.endSession(session) == .partial(AudioClip(samples: [1, 2]), lost: loss(interrupted: true)))
    }

    /// The same splice with the reconnect actually taking time. Positions advance only on
    /// capture, so the two engines' samples sit adjacent while the clock between them ran
    /// for a third of a second, and that gap is exactly what a head measured off the newest
    /// buffer would charge to this session's warm-up. The head was captured on time: what
    /// this press lost is its middle, and saying it was also cut where the microphone was
    /// not open would be a second loss that never happened.
    ///
    /// The splice tests either side of this one stamp the replacement at `after(1)`, which
    /// simulates a reconnect that took no time at all - the one quantity that makes the
    /// error visible. This is the unit-level guard on it; `DictationTests` holds the same
    /// press end to end.
    @Test func aSessionSplicedAcrossARealOutageIsNotAlsoUnopened() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try opened(capture)
        hardware.engines[0].appending([1], origin)
        hardware.engines[0].onConfigurationChange()
        hardware.engines[1].appending([2], after(1 + AudioClip.sampleCount(for: 0.3)))
        #expect(try capture.endSession(session) == .partial(AudioClip(samples: [1, 2]), lost: loss(interrupted: true)))
    }

    /// The press after the one the device changed under hears one engine only: the break
    /// is behind it, so its clip is whole.
    @Test func aSessionBegunAfterAConfigurationChangeIsWhole() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let spanning = try opened(capture)
        hardware.engines[0].appending([1], origin)
        hardware.engines[0].onConfigurationChange()
        _ = capture.endSession(spanning)

        let session = try capture.beginSession(at: after(1), preRoll: 0)
        hardware.engines[2].appending([2], after(1))
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [2])))
    }

    /// The same splice by the other door: the microphone died mid-session and the device
    /// that appeared brought it back, so the clip is two engines' audio with the outage
    /// taken out of the middle of it.
    @Test func aSessionThatSpansAnOutageIsPartial() throws {
        let hardware = FakeHardware(launches: [nil, NoDevice()])
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try opened(capture)
        hardware.engines[0].appending([1], origin)
        hardware.engines[0].onConfigurationChange()
        try hardware.changeDefaultInput()
        hardware.engines[1].appending([2], after(1))
        #expect(try capture.endSession(session) == .partial(AudioClip(samples: [1, 2]), lost: loss(interrupted: true)))
    }

    /// The only microphone is unplugged mid-hold: the replacement cannot launch, capture
    /// is failed for a while, and the plug-back-in (a default input change) brings it
    /// back before the speaker has let go.
    @Test func aReplacementThatCannotLaunchIsFailedUntilTheDefaultInputChanges() throws {
        let hardware = FakeHardware(launches: [nil, NoDevice()])
        let capture = AudioCapture(hardware: hardware)
        _ = try opened(capture)
        hardware.engines[0].onConfigurationChange()
        #expect(failure(of: capture, as: NoDevice.self) == NoDevice())
        #expect(hardware.engines.count == 1)
        #expect(capture.outages.count == 0)

        try hardware.changeDefaultInput()
        #expect(isRunning(capture))
        #expect(hardware.engines.count == 2)
        #expect(capture.outages.count == 1)
        #expect(capture.outages.total > .zero)
        #expect(capture.deviceChanges == 0)
    }

    /// A device that appears but cannot feed the pipeline either extends the outage
    /// rather than beginning another; the next one that can ends it.
    @Test func aRecoveryThatFailsAgainExtendsTheSameOutage() throws {
        let hardware = FakeHardware(launches: [nil, NoDevice(), BadBuffer()])
        let capture = AudioCapture(hardware: hardware)
        _ = try opened(capture)
        hardware.engines[0].onConfigurationChange()
        try hardware.changeDefaultInput()
        #expect(failure(of: capture, as: BadBuffer.self) == BadBuffer())
        try hardware.changeDefaultInput()
        #expect(isRunning(capture))
        #expect(capture.outages.count == 1)
    }

    /// While a session's engine is running, a default input change is that engine's to
    /// notice (macOS posts it a configuration change); relaunching here too would launch
    /// twice per change.
    @Test func aDefaultInputChangeWhileRunningLaunchesNothing() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware)
        _ = try opened(capture)
        try hardware.changeDefaultInput()
        #expect(hardware.engines.count == 1)
        #expect(isRunning(capture))
        #expect(capture.deviceChanges == 0)
    }

    /// Plugging a microphone in while nobody is dictating opens nothing. The watch runs
    /// for the whole started period because a session's failed engine has no other way to
    /// hear that a device came back - it must never be read as a reason to start
    /// listening when no session is open.
    @Test func aDefaultInputChangeWhileShutOpensNoMicrophone() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware)
        try capture.start(grant, atRest: .shut)
        try hardware.changeDefaultInput()
        #expect(hardware.engines.isEmpty)
        #expect(isListening(capture))
    }

    /// A session that ended while its engine was failed leaves nothing running, so the
    /// device that appears afterwards finds a shut microphone and leaves it shut.
    @Test func aDeviceAppearingAfterAFailedSessionEndedOpensNoMicrophone() throws {
        let hardware = FakeHardware(launches: [nil, NoDevice()])
        let capture = AudioCapture(hardware: hardware)
        let session = try opened(capture)
        hardware.engines[0].onConfigurationChange()
        _ = capture.endSession(session)
        try hardware.changeDefaultInput()
        #expect(hardware.engines.count == 1)
        #expect(isListening(capture))
    }

    @Test func aBufferTheTapCannotConvertFailsCapture() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware)
        _ = try opened(capture)
        hardware.engines[0].onFailure(BadBuffer())
        #expect(failure(of: capture, as: BadBuffer.self) == BadBuffer())
        #expect(hardware.engines[0].disposed)
    }

    /// A replaced engine's late failure says nothing about the engine now running.
    @Test func aCallbackFromAReplacedEngineIsStale() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware)
        _ = try opened(capture)
        hardware.engines[0].onConfigurationChange()
        hardware.engines[0].onFailure(BadBuffer())
        hardware.engines[0].onConfigurationChange()
        #expect(isRunning(capture))
        #expect(hardware.engines.count == 2)
        #expect(!hardware.engines[1].disposed)
    }

    /// Quitting mid-hold: the key is still down, so there is a microphone to give back.
    @Test func stopDuringASessionDisposesTheEngineAndTheWatch() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware)
        _ = try opened(capture)
        capture.stop()
        if case .stopped = capture.state {} else { Issue.record("stop did not stop") }
        #expect(hardware.engines[0].disposed)
        #expect(!hardware.isWatching)
        #expect(hardware.watchDisposals == 1)
    }

    @Test func stopWhileShutDisposesTheWatch() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware)
        try capture.start(grant, atRest: .shut)
        capture.stop()
        if case .stopped = capture.state {} else { Issue.record("stop did not stop") }
        #expect(!hardware.isWatching)
        #expect(hardware.watchDisposals == 1)
    }

    @Test func stopWhileFailedDisposesTheWatch() throws {
        let hardware = FakeHardware(launches: [nil, NoDevice()])
        let capture = AudioCapture(hardware: hardware)
        _ = try opened(capture)
        hardware.engines[0].onConfigurationChange()
        capture.stop()
        #expect(!hardware.isWatching)
    }

    /// A start that cannot watch the input device leaves nothing behind, and says why.
    /// Capture that cannot hear a device appear could never recover a session's engine,
    /// so half-starting is worse than not starting.
    @Test func aStartThatCannotWatchThrowsAndLeavesNothingStarted() throws {
        let hardware = FakeHardware(watch: NoDevice())
        let capture = AudioCapture(hardware: hardware)
        #expect(throws: NoDevice.self) { try capture.start(grant, atRest: .shut) }
        #expect(!hardware.isWatching)
        if case .stopped = capture.state {} else { Issue.record("a failed start should leave capture stopped") }
    }

    @Test func startAgainResetsTheCounts() throws {
        let hardware = FakeHardware(launches: [nil, NoDevice(), nil, nil])
        let capture = AudioCapture(hardware: hardware)
        _ = try opened(capture)
        hardware.engines[0].onConfigurationChange()
        try hardware.changeDefaultInput()
        hardware.engines[1].onConfigurationChange()
        #expect(capture.deviceChanges == 1)
        #expect(capture.outages.count == 1)
        try capture.start(grant, atRest: .shut)
        #expect(capture.deviceChanges == 0)
        #expect(capture.outages.count == 0)
        #expect(capture.outages.total == .zero)
        #expect(hardware.engines[2].disposed)
        #expect(hardware.watchDisposals == 1)
        #expect(hardware.isWatching)
        #expect(isListening(capture))
    }
}
