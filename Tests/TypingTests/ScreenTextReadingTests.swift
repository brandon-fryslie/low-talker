import ApplicationServices
import Testing
@testable import Typing

/// The rule that turns one `kAXValue` answer into a reading, asked without a window server.
///
/// `TargetApp.text(from:value:)` is the pure half of the reading `focus` and `read` make.
/// Its whole job is telling "this element holds no text" apart from "this read failed",
/// because `ScreenText.shows` spends a silent baseline as a zero and would otherwise
/// confirm text as typed that the element was already holding. The mirror of
/// `SystemAlertsTests`, on the reading one level down. [LAW:behavior-not-structure]
@Suite struct ScreenTextReadingTests {
    @Test func anElementThatAnswersWithTextReadsAsThatText() throws {
        let read = try TargetApp.text(from: .success, value: "hello" as CFTypeRef)
        #expect(read == .reads(try #require(NonEmptyText("hello"))))
    }

    /// The distinction the type exists for, kept at the edge that produces it.
    @Test func anElementThatAnswersWithTheEmptyStringSaysSoAndNotThatItIsEmpty() throws {
        #expect(try TargetApp.text(from: .success, value: "" as CFTypeRef) == .answeredEmpty)
    }

    /// The two `AXError`s that mean the attribute is absent, which `SystemAlerts` and
    /// `PasteMenuItem` also count as absence. An element really holding nothing is a
    /// reading, and a run may act on it.
    @Test func theTwoAnswersThatMeanThereIsNoTextAreAReading() throws {
        #expect(try TargetApp.text(from: .noValue, value: nil) == .noValue)
        #expect(try TargetApp.text(from: .attributeUnsupported, value: nil) == .noValue)
    }

    @Test func anAnswerThatIsNotAStringCarriesNoText() throws {
        #expect(try TargetApp.text(from: .success, value: 42 as CFTypeRef) == .noValue)
    }

    /// The hole this closes. A busy app answers `.cannotComplete` inside the half-second
    /// messaging timeout, and reading that as "no text" hands `shows` a baseline of zero
    /// for an element that may have been holding the very text about to be typed - so the
    /// run would confirm its own keystrokes against text that was already there.
    @Test func aReadThatFailedIsNotAnElementHoldingNothing() {
        for failure: AXError in [.cannotComplete, .apiDisabled, .invalidUIElement, .notImplemented] {
            #expect(throws: ScreenUnreadable.self) {
                try TargetApp.text(from: failure, value: nil)
            }
        }
    }

    /// A failed read is worth riding out rather than ending a wait on: an app that will not
    /// answer right now may answer in two milliseconds, which is what `wait` polls for.
    @Test func aFailedReadIsWorthWaitingOut() {
        #expect(ScreenUnreadable.textUnreadable(.cannotComplete).mayPassWithTime)
    }

    /// The refusal cites the code it got, for the reason `AlertsUnreadable` does: whoever
    /// is debugging from the message needs to know which failure this was.
    @Test func theRefusalNamesTheErrorItGot() {
        let said = "\(ScreenUnreadable.textUnreadable(.cannotComplete))"
        #expect(said.contains("\(AXError.cannotComplete.rawValue)"))
        #expect(said.contains("unknown"))
    }
}
