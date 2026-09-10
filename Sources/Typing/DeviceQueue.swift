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
/// Serial, and one shared by the keyboard and the mouse a client posts through, because
/// the helper takes their reports as one sequence: two in flight at once would be ordered
/// by its lock rather than by the order they were asked in. A value handed to both rather
/// than a static, so one client never waits on another's. [LAW:no-shared-mutable-globals]
public final class DeviceQueue: Sendable {
    private let queue = DispatchQueue(label: "Typing.DeviceQueue")

    public init() {}

    /// Runs `call` on the queue and resumes with what it threw, if anything. Handed over
    /// on the caller's actor, so calls made there run in the order they were made.
    func run(isolation: isolated (any Actor)? = #isolation, _ call: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: call)) }
        }
    }
}
