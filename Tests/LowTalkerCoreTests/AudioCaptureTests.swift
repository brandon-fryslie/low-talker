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
    private(set) var engines: [Engine] = []
    private var onDefaultInputChange: (@MainActor () -> Void)?
    private(set) var watchDisposals = 0

    init(launches: [(any Error)?] = []) {
        self.launches = launches
    }

    func launch(appending: @escaping @Sendable ([Float], HostTime) -> Void, onFailure: @escaping @MainActor (any Error) -> Void, onConfigurationChange: @escaping @MainActor () -> Void) throws -> Disposal {
        if let error = launches.isEmpty ? nil : launches.removeFirst() { throw error }
        let engine = Engine(appending: appending, onFailure: onFailure, onConfigurationChange: onConfigurationChange)
        engines.append(engine)
        return { engine.disposed = true }
    }

    func watchDefaultInput(_ onChange: @escaping @MainActor () -> Void) throws -> Disposal {
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

    private func failure<E: Error & Equatable>(of capture: AudioCapture, as: E.Type) -> E? {
        if case .failed(let error) = capture.state { return error as? E }
        return nil
    }

    /// The loss a partial capture is expected to carry. A `Loss` refuses to be nothing,
    /// so an expectation of one is spelled out here and the test reads as an equality.
    private func loss(scrolledOff: Int = 0, interrupted: Bool = false) throws -> CapturedAudio.Loss {
        try #require(CapturedAudio.Loss(scrolledOff: scrolledOff, interrupted: interrupted))
    }

    @Test func startLaunchesAnEngineAndWatchesTheDefaultInput() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware)
        try capture.start(grant)
        #expect(isRunning(capture))
        #expect(hardware.engines.count == 1)
        #expect(hardware.isWatching)
    }

    @Test func whatTheEngineCapturesIsWhatTheRingHolds() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try capture.start(grant)
        let session = capture.beginSession(at: origin, preRoll: 0)
        hardware.engines[0].appending([1, 2, 3], origin)
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2, 3])))
    }

    /// The moment names a position, not the call: a session begun at a moment the
    /// microphone has already passed reaches back to it.
    @Test func aSessionBegunAtAnEarlierMomentReachesBackToIt() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try capture.start(grant)
        hardware.engines[0].appending([1, 2, 3, 4], origin)
        let session = capture.beginSession(at: after(2), preRoll: 0)
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [3, 4])))
    }

    /// The key went down between two buffers, so the moment is later than anything
    /// captured. A session cannot begin in audio that does not exist yet: it begins at
    /// the newest sample and holds what comes after.
    @Test func aSessionBegunAfterTheNewestSampleBeginsAtTheNewestSample() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try capture.start(grant)
        hardware.engines[0].appending([1, 2], origin)
        let session = capture.beginSession(at: after(9), preRoll: 0)
        hardware.engines[0].appending([3], after(2))
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [3])))
    }

    /// A hold longer than the ring retains: the first of what was said was overwritten by
    /// the last of it before the key came up. What comes back is the tail, and it says how
    /// much of the head is gone rather than passing for the whole utterance.
    @Test func aSessionWhoseHeadTheRingDroppedSaysHowMuchIsGone() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(retaining: AudioClip.duration(for: 4), hardware: hardware, startingAt: origin)
        try capture.start(grant)
        let session = capture.beginSession(at: origin, preRoll: 0)
        hardware.engines[0].appending([1, 2, 3, 4, 5, 6], origin)
        #expect(try capture.endSession(session) == .partial(AudioClip(samples: [3, 4, 5, 6]), lost: loss(scrolledOff: 2)))
    }

    /// A pre-roll reaching back before the first sample ever captured is not lost audio:
    /// there was none there to lose, which is the ordinary state of the first press after
    /// a start.
    @Test func aPreRollReachingBeforeTheFirstSampleIsNotALoss() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try capture.start(grant)
        let session = capture.beginSession(at: origin)
        hardware.engines[0].appending([1, 2], origin)
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2])))
    }

    /// The ring survives the engine: samples from before the change are still there
    /// after it, followed by the new engine's - spliced, since nothing was captured in
    /// between and no position advanced while nothing was. A session open across the
    /// change is told so; the samples themselves have no seam to find it by.
    @Test func aConfigurationChangeReplacesTheEngineAndSplicesTheRing() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try capture.start(grant)
        let session = capture.beginSession(at: origin, preRoll: 0)
        hardware.engines[0].appending([1], origin)
        hardware.engines[0].onConfigurationChange()
        #expect(hardware.engines[0].disposed)
        #expect(hardware.engines.count == 2)
        #expect(capture.deviceChanges == 1)
        #expect(isRunning(capture))
        hardware.engines[1].appending([2], after(1))
        #expect(try capture.endSession(session) == .partial(AudioClip(samples: [1, 2]), lost: loss(interrupted: true)))
    }

    /// A session begun after the change hears one engine only: the break is behind it,
    /// so its clip is whole.
    @Test func aSessionBegunAfterAConfigurationChangeIsWhole() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try capture.start(grant)
        hardware.engines[0].appending([1], origin)
        hardware.engines[0].onConfigurationChange()
        let session = capture.beginSession(at: after(1), preRoll: 0)
        hardware.engines[1].appending([2], after(1))
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [2])))
    }

    /// The same splice by the other door: capture failed mid-session and the device that
    /// appeared brought it back, so the clip is two engines' audio with the outage taken
    /// out of the middle of it.
    @Test func aSessionThatSpansAnOutageIsPartial() throws {
        let hardware = FakeHardware(launches: [nil, NoDevice()])
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try capture.start(grant)
        let session = capture.beginSession(at: origin, preRoll: 0)
        hardware.engines[0].appending([1], origin)
        hardware.engines[0].onConfigurationChange()
        try hardware.changeDefaultInput()
        hardware.engines[1].appending([2], after(1))
        #expect(try capture.endSession(session) == .partial(AudioClip(samples: [1, 2]), lost: loss(interrupted: true)))
    }

    /// The only microphone is unplugged: the replacement cannot launch, capture is
    /// failed for a while, and the plug-back-in (a default input change) brings it back.
    @Test func aReplacementThatCannotLaunchIsFailedUntilTheDefaultInputChanges() throws {
        let hardware = FakeHardware(launches: [nil, NoDevice()])
        let capture = AudioCapture(hardware: hardware)
        try capture.start(grant)
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
        try capture.start(grant)
        hardware.engines[0].onConfigurationChange()
        try hardware.changeDefaultInput()
        #expect(failure(of: capture, as: BadBuffer.self) == BadBuffer())
        try hardware.changeDefaultInput()
        #expect(isRunning(capture))
        #expect(capture.outages.count == 1)
    }

    /// While running, a default input change is the engine's to notice (macOS posts it
    /// a configuration change); relaunching here too would launch twice per change.
    @Test func aDefaultInputChangeWhileRunningLaunchesNothing() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware)
        try capture.start(grant)
        try hardware.changeDefaultInput()
        #expect(hardware.engines.count == 1)
        #expect(isRunning(capture))
        #expect(capture.deviceChanges == 0)
    }

    @Test func aBufferTheTapCannotConvertFailsCapture() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware)
        try capture.start(grant)
        hardware.engines[0].onFailure(BadBuffer())
        #expect(failure(of: capture, as: BadBuffer.self) == BadBuffer())
        #expect(hardware.engines[0].disposed)
    }

    /// A replaced engine's late failure says nothing about the engine now running.
    @Test func aCallbackFromAReplacedEngineIsStale() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware)
        try capture.start(grant)
        hardware.engines[0].onConfigurationChange()
        hardware.engines[0].onFailure(BadBuffer())
        hardware.engines[0].onConfigurationChange()
        #expect(isRunning(capture))
        #expect(hardware.engines.count == 2)
        #expect(!hardware.engines[1].disposed)
    }

    @Test func stopDisposesTheEngineAndTheWatch() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware)
        try capture.start(grant)
        capture.stop()
        if case .stopped = capture.state {} else { Issue.record("stop did not stop") }
        #expect(hardware.engines[0].disposed)
        #expect(!hardware.isWatching)
        #expect(hardware.watchDisposals == 1)
    }

    @Test func stopWhileFailedDisposesTheWatch() throws {
        let hardware = FakeHardware(launches: [nil, NoDevice()])
        let capture = AudioCapture(hardware: hardware)
        try capture.start(grant)
        hardware.engines[0].onConfigurationChange()
        capture.stop()
        #expect(!hardware.isWatching)
    }

    /// A start whose first launch fails leaves nothing behind, and says why.
    @Test func aStartThatCannotLaunchThrowsAndWatchesNothing() throws {
        let hardware = FakeHardware(launches: [NoDevice()])
        let capture = AudioCapture(hardware: hardware)
        #expect(throws: NoDevice.self) { try capture.start(grant) }
        #expect(!hardware.isWatching)
        if case .stopped = capture.state {} else { Issue.record("a failed start should leave capture stopped") }
    }

    @Test func startAgainResetsTheCounts() throws {
        let hardware = FakeHardware(launches: [nil, NoDevice(), nil, nil])
        let capture = AudioCapture(hardware: hardware)
        try capture.start(grant)
        hardware.engines[0].onConfigurationChange()
        try hardware.changeDefaultInput()
        hardware.engines[1].onConfigurationChange()
        #expect(capture.deviceChanges == 1)
        #expect(capture.outages.count == 1)
        try capture.start(grant)
        #expect(capture.deviceChanges == 0)
        #expect(capture.outages.count == 0)
        #expect(capture.outages.total == .zero)
        #expect(hardware.engines[2].disposed)
        #expect(hardware.watchDisposals == 1)
        #expect(hardware.isWatching)
    }
}
