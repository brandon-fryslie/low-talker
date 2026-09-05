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
        let appending: @Sendable ([Float]) -> Void
        let onFailure: @MainActor (any Error) -> Void
        let onConfigurationChange: @MainActor () -> Void
        var disposed = false

        init(appending: @escaping @Sendable ([Float]) -> Void, onFailure: @escaping @MainActor (any Error) -> Void, onConfigurationChange: @escaping @MainActor () -> Void) {
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

    func launch(appending: @escaping @Sendable ([Float]) -> Void, onFailure: @escaping @MainActor (any Error) -> Void, onConfigurationChange: @escaping @MainActor () -> Void) throws -> Disposal {
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

    private func isRunning(_ capture: AudioCapture) -> Bool {
        if case .running = capture.state { return true }
        return false
    }

    private func failure<E: Error & Equatable>(of capture: AudioCapture, as: E.Type) -> E? {
        if case .failed(let error) = capture.state { return error as? E }
        return nil
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
        let capture = AudioCapture(hardware: hardware)
        try capture.start(grant)
        let session = capture.beginSession(preRoll: 0)
        hardware.engines[0].appending([1, 2, 3])
        #expect(capture.endSession(session).samples == [1, 2, 3])
    }

    /// The ring survives the engine: samples from before the change are still there
    /// after it, followed by the new engine's.
    @Test func aConfigurationChangeReplacesTheEngineAndKeepsTheRing() throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware)
        try capture.start(grant)
        let session = capture.beginSession(preRoll: 0)
        hardware.engines[0].appending([1])
        hardware.engines[0].onConfigurationChange()
        #expect(hardware.engines[0].disposed)
        #expect(hardware.engines.count == 2)
        #expect(capture.deviceChanges == 1)
        #expect(isRunning(capture))
        hardware.engines[1].appending([2])
        #expect(capture.endSession(session).samples == [1, 2])
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
        #expect(capture.outages.isEmpty)

        try hardware.changeDefaultInput()
        #expect(isRunning(capture))
        #expect(hardware.engines.count == 2)
        #expect(capture.outages.count == 1)
        #expect(capture.outages[0].error as? NoDevice == NoDevice())
        #expect(capture.outages[0].duration >= .zero)
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
        #expect(capture.outages[0].error as? BadBuffer == BadBuffer())
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
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware)
        try capture.start(grant)
        hardware.engines[0].onConfigurationChange()
        #expect(capture.deviceChanges == 1)
        try capture.start(grant)
        #expect(capture.deviceChanges == 0)
        #expect(hardware.engines[1].disposed)
        #expect(hardware.watchDisposals == 1)
        #expect(hardware.isWatching)
    }
}
