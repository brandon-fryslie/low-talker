@testable import LowTalkerCore
import Testing

/// The wait behind the shape reading: the one place its three endings are decided, and the
/// half of an interrupted reading a suite can reach. The hardware half - that a report lands at
/// all - is `lowtalker mic shape`'s. Every wait here runs on a clock the test advances, so an
/// ending is a fact about the wait and not about how the machine happened to schedule it.
@MainActor
@Suite struct ShapeChangeArrivalTests {
    @Test func aReportAlreadyPastTheOnesSeenEndsTheWaitAtOnce() async throws {
        let arrival = ShapeChangeAtRest.Arrival()
        let clock = StepClock()
        arrival.arrived()
        #expect(try await arrival.wait(past: 0, for: .seconds(10), on: clock) == .arrived)
        #expect(clock.now.since == .zero)
    }

    /// The report lands while the wait is under way, and the wait ends on it rather than on its
    /// deadline: the clock has moved by the polls it took to notice, and no further.
    @Test func aReportThatLandsDuringTheWaitEndsIt() async throws {
        let arrival = ShapeChangeAtRest.Arrival()
        let clock = StepClock()
        var asks = 0
        let outcome = try await arrival.wait(past: 0, for: .seconds(10), on: clock, stoppingFor: {
            asks += 1
            if asks == 3 { arrival.arrived() }
            return false
        })
        #expect(outcome == .arrived)
        #expect(clock.now.since < .seconds(1))
    }

    @Test func aWaitNobodyReportsToRunsOut() async throws {
        let arrival = ShapeChangeAtRest.Arrival()
        let clock = StepClock()
        #expect(try await arrival.wait(past: 0, for: .milliseconds(30), on: clock) == .ranOut)
        #expect(clock.now.since >= .milliseconds(30))
    }

    /// The interrupt is read between turns, so a stop that is already true ends the wait before
    /// its deadline and reads as stopped rather than as a report that never came.
    @Test func aStopEndsTheWaitAndIsToldApartFromRunningOut() async throws {
        let arrival = ShapeChangeAtRest.Arrival()
        let clock = StepClock()
        #expect(try await arrival.wait(past: 0, for: .seconds(10), on: clock, stoppingFor: { true }) == .stopped)
        #expect(clock.now.since == .zero)
    }

    /// A report already past the count is an answer even when the stop is raised: the question
    /// was answered before it was withdrawn.
    @Test func aReportBeatsAStop() async throws {
        let arrival = ShapeChangeAtRest.Arrival()
        arrival.arrived()
        #expect(try await arrival.wait(past: 0, for: .seconds(10), on: StepClock(), stoppingFor: { true }) == .arrived)
    }
}
