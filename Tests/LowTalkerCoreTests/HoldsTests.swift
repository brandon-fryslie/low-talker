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

    struct Unaskable: Error {}

    @Test func aFailedAskIsThrown() async {
        await #expect(throws: Unaskable.self) {
            try await holds(within: .seconds(1), askingEvery: .milliseconds(5)) { throw Unaskable() }
        }
    }
}
