import Foundation
import LowTalkerCore
import ServiceManagement
import Testing

/// The line each launch logs per retired helper label, read as the value it is written from.
/// The app target has no harness, so this is where the event's facts are held.
@Suite struct HelperRetirementTests {
    private let label = "ai.promptctl.low-talker.keyboardd"

    @Test func aRegisteredJobUnregistersAtNoticeLevel() {
        let retirement = HelperRetirement(label: label, found: .enabled, unregisterError: nil)
        #expect(retirement.outcome == .unregistered)
        #expect(retirement.level == .default)
        #expect(retirement.description ==
            "retired keyboard helper ai.promptctl.low-talker.keyboardd: SMAppService.Status 1 before, unregistered")
    }

    /// The header's answer for a job already gone, on every launch after the one that retired
    /// it; logged at error level it would bury a real failure under one per launch.
    @Test func nothingRegisteredIsAnOrdinaryAnswer() {
        let jobNotFound = NSError(domain: SMAppServiceErrorDomain, code: kSMErrorJobNotFound)
        let retirement = HelperRetirement(label: label, found: .notRegistered, unregisterError: jobNotFound)
        #expect(retirement.outcome == .nothingRegistered)
        #expect(retirement.level == .default)
        #expect(retirement.description.hasSuffix("SMAppService.Status 0 before, nothing registered"))
    }

    /// What macOS 15 answers for a label already retired: success, after reading nothing
    /// registered. Measured on studious; the line must not claim a job was dropped.
    @Test func successOnNothingRegisteredIsNotAnUnregistering() {
        let retirement = HelperRetirement(label: label, found: .notRegistered, unregisterError: nil)
        #expect(retirement.outcome == .nothingRegistered)
        #expect(retirement.level == .default)
    }

    /// EINVAL is what a bundle without the label's plist answers, measured on macOS 15 and 26.
    @Test func anyOtherErrorIsAFailureAtErrorLevel() {
        let missingPlist = NSError(domain: SMAppServiceErrorDomain, code: 22)
        let retirement = HelperRetirement(label: label, found: .notFound, unregisterError: missingPlist)
        #expect(retirement.outcome == .failed(missingPlist.description))
        #expect(retirement.level == .error)
        #expect(retirement.description.contains("SMAppService.Status 3 before, unregister failed: "))
    }
}
