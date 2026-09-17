/// A clock whose hands move only when the code under test sleeps. Nothing here waits
/// on the machine, so what a test assert is the polling loop's behaviour rather
/// than how fast this Mac happened to schedule it: on a loaded runner the first real
/// 5 ms sleep can overrun a one-second window, which is a fact about the runner and
/// not about the loop. [LAW:no-ambient-temporal-coupling]
///
/// Shared by every suite that drives a wait, so there is one clock to get right.
/// [LAW:one-source-of-truth]
final class StepClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var since: Duration
        func advanced(by duration: Duration) -> Instant { Instant(since: since + duration) }
        func duration(to other: Instant) -> Duration { other.since - since }
        static func < (a: Instant, b: Instant) -> Bool { a.since < b.since }
    }

    private(set) var now = Instant(since: .zero)
    let minimumResolution: Duration = .zero
    /// Run at each tick with the instant the hands moved to, before the sleeper wakes: where
    /// a test puts what the world does while the code under test sleeps. A sleep on this
    /// clock never suspends, so nothing else gets a turn to do it.
    var onTick: ((Instant) -> Void)?

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        now = deadline
        onTick?(deadline)
    }
}
