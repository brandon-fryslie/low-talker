import LowTalkerCore
import Testing

@Suite struct HoldsTests {
    @Test func trueTheAskItComesToHold() async throws {
        var asks = 0
        let held = try await holds(within: .seconds(1), askingEvery: .milliseconds(5)) { asks += 1; return asks == 3 }
        #expect(held)
        #expect(asks == 3)
    }

    @Test func falseOnlyAfterTheWholeWindowAndOneLastAsk() async throws {
        let started = ContinuousClock.now
        var lastAsk = started
        let held = try await holds(within: .milliseconds(40), askingEvery: .milliseconds(10)) { lastAsk = .now; return false }
        #expect(!held)
        #expect(lastAsk - started >= .milliseconds(40))
    }

    /// The last ask falls after the window, so a condition that comes to hold only
    /// then still counts.
    @Test func aConditionThatHoldsOnlyOnceTheWindowHasPassedStillCounts() async throws {
        let started = ContinuousClock.now
        let held = try await holds(within: .milliseconds(30), askingEvery: .milliseconds(10)) {
            ContinuousClock.now - started >= .milliseconds(30)
        }
        #expect(held)
    }

    struct Unaskable: Error {}

    @Test func aFailedAskIsThrown() async {
        await #expect(throws: Unaskable.self) {
            try await holds(within: .seconds(1), askingEvery: .milliseconds(5)) { throw Unaskable() }
        }
    }
}
