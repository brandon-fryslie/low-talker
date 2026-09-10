import Dispatch
import Keystrokes
import LowTalkerCore
import Pointing
import Synchronization
import Testing
import Typing

/// What reached the devices, in the order it arrived.
private final class Journal: Sendable {
    private let entries = Mutex<[String]>([])

    var log: [String] { entries.withLock { $0 } }

    func record(_ entry: String) { entries.withLock { $0.append(entry) } }
}

/// A device that holds the thread a key-down is made on until the test acknowledges it,
/// as the helper's round trip holds it until the report is posted.
private final class BlockingKeyPress: KeyPress {
    struct Unacknowledged: Error {}

    private let journal: Journal
    private let acknowledged = DispatchSemaphore(value: 0)
    private let held = Mutex(false)

    init(journal: Journal) { self.journal = journal }

    /// Whether a key-down is holding its thread right now.
    var blocking: Bool { held.withLock { $0 } }

    func acknowledge() { acknowledged.signal() }

    /// Bounded, so a key-down made where it should not be fails the test rather than
    /// holding the suite: the deadline is past any the test itself waits for.
    func down(_ usage: Usage) throws {
        held.withLock { $0 = true }
        defer { held.withLock { $0 = false } }
        guard acknowledged.wait(timeout: .now() + .seconds(30)) == .success else { throw Unacknowledged() }
        journal.record("down \(usage.rawValue)")
    }

    func releaseAll() throws { journal.record("up") }
}

/// A pointing device that answers at once, into the journal a keyboard writes.
private struct JournalPointing: Pointing {
    let journal: Journal

    func down(_ button: Button) throws { journal.record("down button \(button.rawValue)") }
    func releaseAll() throws { journal.record("release") }
    func move(by delta: Move) throws { journal.record("move \(delta.x.value) \(delta.y.value)") }
    func scroll(by delta: Scroll) throws { journal.record("scroll \(delta.vertical.value) \(delta.horizontal.value)") }
}

/// Where a guarded device waits for its answer.
@Suite @MainActor struct DeviceQueueTests {
    private static var nothingInFront: TargetApp {
        TargetApp(bundleID: BundleID(rawValue: "com.example.nothing"), interrupt: Interrupt())
    }

    /// The main actor is where the hotkey's tap is heard, so a key-down must not hold it for
    /// the device's answer. The device is read from the main actor while it is still
    /// holding the key-down's thread; a key-down made on the main actor would leave nothing
    /// to read it until the hold was over, and the hold only ends at the deadline.
    @Test func aKeyDownWaitsForTheDeviceOffTheMainActor() async throws {
        let journal = Journal()
        let device = BlockingKeyPress(journal: journal)
        let keyboard = GuardedKeyboard(keyboard: device, queue: DeviceQueue(), interrupt: Interrupt(), screen: Self.nothingInFront)
        let pressed = Task { try await keyboard.down(Usage(rawValue: 0x04)) }
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { device.blocking })
        device.acknowledge()
        try await pressed.value
        #expect(journal.log == ["down 4"])
    }

    /// A key and then a move, asked for on one queue, arrive in that order however long the
    /// key's answer takes. On a queue of its own the move would land while the key waits.
    @Test func aKeyAndAMoveOnOneQueueArriveInTheOrderAsked() async throws {
        let journal = Journal()
        let device = BlockingKeyPress(journal: journal)
        let queue = DeviceQueue()
        let keyboard = GuardedKeyboard(keyboard: device, queue: queue, interrupt: Interrupt(), screen: Self.nothingInFront)
        let mouse = GuardedMouse(pointing: JournalPointing(journal: journal), queue: queue, interrupt: Interrupt(), screen: Self.nothingInFront)
        let pressed = Task { try await keyboard.down(Usage(rawValue: 0x04)) }
        let moved = Task { try await mouse.move(by: Move(x: Count(clamping: 3), y: Count(clamping: 4))) }
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { device.blocking })
        device.acknowledge()
        try await pressed.value
        try await moved.value
        #expect(journal.log == ["down 4", "move 3 4"])
    }
}
