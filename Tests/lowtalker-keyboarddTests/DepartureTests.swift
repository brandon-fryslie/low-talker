import Testing
@testable import lowtalker_keyboardd

/// The first reason to leave is the one that leaves; every later one finds the process
/// already going.
@Suite struct DepartureTests {
    @Test func theFirstClaimWinsAndEveryLaterOneIsRefused() {
        let departure = Departure()
        #expect(departure.claim())
        #expect(!departure.claim())
        #expect(!departure.claim())
    }
}
