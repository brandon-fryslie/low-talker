import ApplicationServices
import Testing
@testable import Typing

/// The rule that decides whether a click may fire, asked without a window server.
///
/// `SystemAlerts.count(from:value:)` is the pure half of the reading `GuardedMouse` makes
/// before every pointer report, so these are the branches that stand between an agent's
/// click and somebody else's Allow button.
@Suite struct SystemAlertsTests {
    /// The usual state: the owner is launched to show an alert and exits again, and one
    /// that is running but has not finished launching has no windows attribute yet.
    /// Neither is an alert.
    @Test func anOwnerWithNothingToShowIsNoAlert() throws {
        #expect(try SystemAlerts.count(from: .noValue, value: nil) == 0)
        #expect(try SystemAlerts.count(from: .attributeUnsupported, value: nil) == 0)
    }

    @Test func theWindowsTheOwnerListsAreTheAlerts() throws {
        #expect(try SystemAlerts.count(from: .success, value: [] as CFArray) == 0)
        #expect(try SystemAlerts.count(from: .success, value: ["one", "two"] as CFArray) == 2)
    }

    /// [LAW:no-silent-failure] The refusal is not read as an empty screen. Reporting zero
    /// here would let "you cannot see what is on the screen" stand in for "go ahead and
    /// click", which is the whole failure this reading exists to prevent.
    @Test func anOwnerThatWillNotAnswerIsNotAnEmptyScreen() {
        #expect(throws: AlertsUnreadable.self) {
            try SystemAlerts.count(from: .cannotComplete, value: nil)
        }
    }

    /// An answer that arrived in the wrong shape is its own outcome, and says so. Reusing
    /// the refusal here would print "AXError 0" - citing success as the reason nothing was
    /// said - to whoever is debugging from the message.
    @Test func anAnswerThatIsNotAListOfWindowsSaysThatAndNotAXErrorZero() {
        #expect(throws: AlertsUnreadable.self) {
            try SystemAlerts.count(from: .success, value: "not a list" as CFString)
        }
        #expect("\(AlertsUnreadable.answeredWithSomethingElse)" != "\(AlertsUnreadable.refused(.success))")
        #expect(!"\(AlertsUnreadable.answeredWithSomethingElse)".contains("AXError"))
    }
}
