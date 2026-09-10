import Dispatch

/// Where a device call waits for its acknowledgement: a serial queue of its own, off the
/// main actor and off the cooperative pool.
///
/// A report to the keyboard or the mouse blocks the thread it is made on until the far
/// side answers, and that wait is the pacing the driver needs, so it stays; what moves is
/// the thread. On the main actor it held the thread the hotkey's tap is heard on for as
/// long as the insert took - ten seconds for a long sentence - and a tap that cannot be
/// heard is one macOS switches off. On the cooperative pool it would hold one of the few
/// threads the rest of the process runs on, which is how `HelperKeyboardTests` once
/// starved a three-core runner. A queue nothing else runs on is the one place the wait
/// holds up nobody. [LAW:no-ambient-temporal-coupling]
///
/// Serial, and one for both devices, because the helper takes a keyboard report and a
/// mouse report from one client as one sequence: two in flight at once would be ordered
/// by its lock rather than by the order they were asked in.
enum DeviceQueue {
    private static let queue = DispatchQueue(label: "Typing.DeviceQueue")

    /// Runs `call` on the queue and resumes with what it threw, if anything.
    static func run(_ call: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: call)) }
        }
    }
}
