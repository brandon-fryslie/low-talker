import Dispatch
import Keystrokes
import LowTalkerCore
import Synchronization
import Testing
import Typing

/// A device that holds the thread a key-down is made on until the test acknowledges it,
/// as the helper's round trip holds it until the report is posted.
private final class BlockingKeyPress: KeyPress {
    struct Unacknowledged: Error {}

    private struct State {
        var log: [String] = []
        var blocking = false
    }

    private let acknowledged = DispatchSemaphore(value: 0)
    private let state = Mutex(State())

    var log: [String] { state.withLock { $0.log } }
    /// Whether a key-down is holding its thread right now.
    var blocking: Bool { state.withLock { $0.blocking } }

    func acknowledge() { acknowledged.signal() }

    /// Bounded, so a key-down made where it should not be fails the test rather than
    /// holding the suite: the deadline is past any the test itself waits for.
    func down(_ usage: Usage) throws {
        state.withLock { $0.blocking = true }
        defer { state.withLock { $0.blocking = false } }
        guard acknowledged.wait(timeout: .now() + .seconds(30)) == .success else { throw Unacknowledged() }
        state.withLock { $0.log.append("down \(usage.rawValue)") }
    }

    func releaseAll() throws { state.withLock { $0.log.append("up") } }
}

/// Where a guarded keyboard waits for its device.
@Suite @MainActor struct GuardedKeyboardTests {
    /// The main actor is where the hotkey's tap is heard, so a key-down must not hold it for
    /// the device's answer. The device is read from the main actor while it is still
    /// holding the key-down's thread; a key-down made on the main actor would leave nothing
    /// to read it until the hold was over, and the hold only ends at the deadline.
    @Test func aKeyDownWaitsForTheDeviceOffTheMainActor() async throws {
        let device = BlockingKeyPress()
        let keyboard = GuardedKeyboard(
            keyboard: device,
            interrupt: Interrupt(),
            screen: TargetApp(bundleID: BundleID(rawValue: "com.example.nothing"), interrupt: Interrupt())
        )
        let pressed = Task { try await keyboard.down(Usage(rawValue: 0x04)) }
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { device.blocking })
        device.acknowledge()
        try await pressed.value
        #expect(device.log == ["down 4"])
    }
}
