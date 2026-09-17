@testable import LowTalkerCore
import Testing

/// The wait behind the shape reading: the one place its three endings are decided, and the
/// half of an interrupted reading a suite can reach. The hardware half - that a report lands at
/// all - is `lowtalker mic shape`'s.
@MainActor
@Suite struct ShapeChangeArrivalTests {
    @Test func aReportAlreadyPastTheOnesSeenEndsTheWaitAtOnce() async throws {
        let arrival = ShapeChangeAtRest.Arrival()
        arrival.arrived()
        #expect(try await arrival.wait(past: 0, for: .seconds(10), stoppingFor: { false }) == .arrived)
    }

    /// The report lands while the wait is under way, from the same actor the listener would
    /// use, and the wait ends on it rather than on its deadline.
    @Test func aReportThatLandsDuringTheWaitEndsIt() async throws {
        let arrival = ShapeChangeAtRest.Arrival()
        let clock = ContinuousClock()
        let started = clock.now
        Task { @MainActor in
            try await Task.sleep(for: .milliseconds(20))
            arrival.arrived()
        }
        #expect(try await arrival.wait(past: 0, for: .seconds(10), stoppingFor: { false }) == .arrived)
        #expect(clock.now - started < .seconds(5))
    }

    @Test func aWaitNobodyReportsToRunsOut() async throws {
        let arrival = ShapeChangeAtRest.Arrival()
        #expect(try await arrival.wait(past: 0, for: .milliseconds(30), stoppingFor: { false }) == .ranOut)
    }

    /// The interrupt is read between turns, so a stop that is already true ends the wait before
    /// its deadline and reads as stopped rather than as a report that never came.
    @Test func aStopEndsTheWaitAndIsToldApartFromRunningOut() async throws {
        let arrival = ShapeChangeAtRest.Arrival()
        #expect(try await arrival.wait(past: 0, for: .seconds(10), stoppingFor: { true }) == .stopped)
    }

    /// A report already past the count is an answer even when the stop is raised: the question
    /// was answered before it was withdrawn.
    @Test func aReportBeatsAStop() async throws {
        let arrival = ShapeChangeAtRest.Arrival()
        arrival.arrived()
        #expect(try await arrival.wait(past: 0, for: .seconds(10), stoppingFor: { true }) == .arrived)
    }
}
