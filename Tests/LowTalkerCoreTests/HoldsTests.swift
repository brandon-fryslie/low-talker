import LowTalkerCore
import Testing

/// A clock whose hands move only when the code under test sleeps. Nothing here waits
/// on the machine, so what these tests assert is the polling loop's behaviour rather
/// than how fast this Mac happened to schedule it: on a loaded runner the first real
/// 5 ms sleep can overrun a one-second window, which is a fact about the runner and
/// not about `holds`. [LAW:no-ambient-temporal-coupling]
private final class StepClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var since: Duration
        func advanced(by duration: Duration) -> Instant { Instant(since: since + duration) }
        func duration(to other: Instant) -> Duration { other.since - since }
        static func < (a: Instant, b: Instant) -> Bool { a.since < b.since }
    }

    private(set) var now = Instant(since: .zero)
    let minimumResolution: Duration = .zero

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        now = deadline
    }
}

@Suite struct HoldsTests {
    @Test func trueTheAskItComesToHold() async throws {
        let clock = StepClock()
        var asks = 0
        let held = try await holds(within: .seconds(1), askingEvery: .milliseconds(5), on: clock) {
            asks += 1
            return asks == 3
        }
        #expect(held)
        #expect(asks == 3)
    }

    @Test func falseOnlyAfterTheWholeWindowAndOneLastAsk() async throws {
        let clock = StepClock()
        var lastAsk = clock.now
        let held = try await holds(within: .milliseconds(40), askingEvery: .milliseconds(10), on: clock) {
            lastAsk = clock.now
            return false
        }
        #expect(!held)
        #expect(lastAsk.since >= .milliseconds(40))
    }

    /// The last ask falls after the window, so a condition that comes to hold only
    /// then still counts.
    @Test func aConditionThatHoldsOnlyOnceTheWindowHasPassedStillCounts() async throws {
        let clock = StepClock()
        let held = try await holds(within: .milliseconds(30), askingEvery: .milliseconds(10), on: clock) {
            clock.now.since >= .milliseconds(30)
        }
        #expect(held)
    }

    struct Unaskable: Error {}

    @Test func aFailedAskIsThrown() async {
        let clock = StepClock()
        await #expect(throws: Unaskable.self) {
            try await holds(within: .seconds(1), askingEvery: .milliseconds(5), on: clock) { throw Unaskable() }
        }
    }

    /// Cancellation reaches the caller through the sleep, the loop's only suspension.
    /// The task is enqueued rather than run inline, so the cancel lands before the
    /// first ask.
    @Test func aCancelledAskThrowsRatherThanAnswering() async throws {
        let clock = StepClock()
        let asking = Task {
            try await holds(within: .seconds(1), askingEvery: .milliseconds(5), on: clock) { false }
        }
        asking.cancel()
        await #expect(throws: CancellationError.self) { try await asking.value }
    }

    /// The default clock is the real one, which is what every caller outside a test
    /// gets: the same contract, asked against wall time.
    @Test func theDefaultClockIsTheRealOne() async throws {
        var asks = 0
        let held = try await holds(within: .seconds(10), askingEvery: .milliseconds(1)) {
            asks += 1
            return asks == 2
        }
        #expect(held)
    }
}
