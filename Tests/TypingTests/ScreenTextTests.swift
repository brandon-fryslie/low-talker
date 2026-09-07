import Foundation
import Testing
@testable import Typing

/// The distinction this type exists for: an app that answers with the empty string is not
/// an app whose screen is empty. Measured on VS Code, frontmost with a document open - its
/// focused element answers `kAXValue` with success and zero characters, exactly as an
/// empty TextEdit document does - and it is why a run that typed all 29 characters
/// correctly once reported `MISMATCH: the screen holds []`.
@Suite struct ScreenTextTests {
    @Test func anAnswerWithTextReadsAsThatText() throws {
        #expect(ScreenText(answer: "hello") == .reads(try #require(NonEmptyText("hello"))))
    }

    /// The invariant is the payload's, not a convention the initialiser keeps: there is no
    /// value of the `reads` case that carries an empty string, so no future call site can
    /// construct the reading that would print as `[]`.
    @Test func thereIsNoReadingThatCarriesNothing() {
        #expect(NonEmptyText("") == nil)
    }

    @Test func anEmptyAnswerIsNotAnEmptyScreen() {
        #expect(ScreenText(answer: "") == .answeredEmpty)
    }

    @Test func aRefusedAnswerIsItsOwnOutcome() {
        #expect(ScreenText(answer: nil) == .noValue)
    }

    /// The two silences are distinguishable from each other, not merely from a reading.
    @Test func theTwoSilencesAreNotTheSameOutcome() {
        #expect(ScreenText(answer: "") != ScreenText(answer: nil))
    }

    /// No silence renders as text a reader could mistake for the screen's contents, and
    /// each says which silence it was.
    @Test func aSilenceDescribesItselfAsOne() {
        #expect("\(ScreenText(answer: "hi"))" == "[hi]")
        #expect("\(ScreenText.answeredEmpty)".hasPrefix("nothing readable"))
        #expect("\(ScreenText.noValue)".hasPrefix("nothing readable"))
        #expect("\(ScreenText.answeredEmpty)" != "\(ScreenText.noValue)")
    }

    @Test func textThatArrivedSinceTheBaselineShows() {
        #expect(ScreenText(answer: "a cat").shows("cat", moreThan: ScreenText(answer: "a ")))
    }

    /// The check is against the baseline and not against zero, so an app already holding
    /// the text does not confirm a run that delivered nothing.
    @Test func textTheScreenAlreadyHeldDoesNotShow() {
        #expect(!ScreenText(answer: "a cat").shows("cat", moreThan: ScreenText(answer: "a cat")))
    }

    /// A silence now is no verdict, so it is never a yes - whatever the baseline was.
    @Test func aSilentReadingIsNeverAYes() {
        #expect(!ScreenText.answeredEmpty.shows("cat", moreThan: ScreenText(answer: "a ")))
        #expect(!ScreenText.noValue.shows("cat", moreThan: ScreenText(answer: "a ")))
        #expect(!ScreenText.answeredEmpty.shows("cat", moreThan: .answeredEmpty))
    }

    /// The other half of the asymmetry, and the case that keeps an empty document
    /// verifiable: a silent baseline is a zero, because either the element really held
    /// nothing - and a later reading is honest evidence the text arrived - or the app
    /// never reports its contents, in which case no later reading is ever `reads` and this
    /// cannot fire. Typing into an empty TextEdit document takes exactly this path.
    @Test func aSilentBaselineCountsAsHavingHeldNothing() {
        #expect(ScreenText(answer: "cat").shows("cat", moreThan: .answeredEmpty))
        #expect(ScreenText(answer: "cat").shows("cat", moreThan: .noValue))
    }
}
