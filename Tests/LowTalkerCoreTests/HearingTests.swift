import Foundation
@testable import LowTalkerCore
import Testing

@Suite struct HearingTests {
    /// A second of margin, in samples, the same rule the engine derives its own by.
    static let margin = AudioClip.sampleCount(for: 1)

    static func word(_ text: String, _ start: Double, _ end: Double) -> Transcript.Word {
        Transcript.Word(text: text, time: start...end, confidence: 0.9)
    }

    static func samples(_ seconds: Double) -> Int {
        AudioClip.sampleCount(for: seconds)
    }

    static func hearing() -> Hearing {
        Hearing(margin: margin, context: 3)
    }

    /// Before any pass, a pass needs more than the margin; after one, only new audio.
    @Test func theFirstPassSettlesNothing() {
        var hearing = Self.hearing()
        #expect(hearing.passable == Self.margin)
        #expect(hearing.prefix.isEmpty)
        hearing.hear([Self.word(" see", 0.2, 0.5), Self.word(" you", 0.6, 0.9)], through: Self.samples(3))
        #expect(hearing.confirmed.isEmpty)
        #expect(hearing.tentative.map(\.text) == [" see", " you"])
        #expect(hearing.cut == 0)
        #expect(hearing.heard == Self.samples(3))
        #expect(hearing.passable == Self.samples(3))
    }

    /// Words two passes agree on settle up to the margin before the later pass's
    /// end, with the later pass's timing; the next pass starts where the first
    /// prefix word does and says the prefix.
    @Test func agreedWordsSettleUpToTheMargin() {
        var hearing = Self.hearing()
        hearing.hear([
            Self.word(" see", 0.2, 0.5), Self.word(" you", 0.6, 0.9), Self.word(" at", 1.0, 1.2), Self.word(" noon", 1.3, 1.8),
        ], through: Self.samples(2))
        hearing.hear([
            Self.word(" see", 0.2, 0.5), Self.word(" you", 0.6, 0.92), Self.word(" at", 1.0, 1.2), Self.word(" noon", 1.3, 1.8), Self.word(" soon", 2.0, 2.4),
        ], through: Self.samples(2.5))
        #expect(hearing.confirmed.map(\.text) == [" see", " you", " at"])
        #expect(hearing.confirmed[1].time == 0.6...0.92)
        #expect(hearing.tentative.map(\.text) == [" noon", " soon"])
        #expect(hearing.prefix.map(\.text) == [" see", " you", " at"])
        #expect(hearing.cut == Self.samples(0.2))
        #expect(hearing.passable == Self.samples(2.5))
        #expect(hearing.partial.text == " see you at noon soon")
    }

    /// The prefix is the last `context` confirmed words, so the cut follows the
    /// confirmed words forward and never reaches back to the utterance's start.
    @Test func thePrefixIsTheLastConfirmedWords() {
        var hearing = Self.hearing()
        let words = [Self.word(" a", 0, 0.1), Self.word(" b", 0.2, 0.3), Self.word(" c", 0.4, 0.5), Self.word(" d", 0.6, 0.7)]
        hearing.hear(words, through: Self.samples(2))
        hearing.hear(words, through: Self.samples(3))
        #expect(hearing.confirmed.map(\.text) == [" a", " b", " c", " d"])
        #expect(hearing.prefix.map(\.text) == [" b", " c", " d"])
        #expect(hearing.cut == Self.samples(0.2))
    }

    /// A word read differently holds back itself and everything after it, however
    /// long ago the later words ended.
    @Test func aDisagreementHoldsBackEverythingAfterIt() {
        var hearing = Self.hearing()
        hearing.hear([Self.word(" a", 0.05, 0.1), Self.word(" b", 0.2, 0.3), Self.word(" c", 0.4, 0.5)], through: Self.samples(2))
        hearing.hear([Self.word(" a", 0.05, 0.1), Self.word(" x", 0.2, 0.3), Self.word(" c", 0.4, 0.5)], through: Self.samples(3))
        #expect(hearing.confirmed.map(\.text) == [" a"])
        #expect(hearing.tentative.map(\.text) == [" x", " c"])
        #expect(hearing.cut == Self.samples(0.05))
    }

    /// The cut never moves back: a pass that settles nothing leaves it where it was.
    @Test func aPassThatSettlesNothingLeavesTheCut() {
        var hearing = Self.hearing()
        hearing.hear([Self.word(" a", 0.05, 0.1)], through: Self.samples(2))
        hearing.hear([Self.word(" a", 0.05, 0.1)], through: Self.samples(3))
        #expect(hearing.cut == Self.samples(0.05))
        hearing.hear([Self.word(" a", 0.05, 0.1)], through: Self.samples(4))
        #expect(hearing.cut == Self.samples(0.05))
        #expect(hearing.confirmed.map(\.text) == [" a"])
        #expect(hearing.tentative.isEmpty)
        #expect(hearing.passable == Self.samples(4))
    }

    /// A pass reads its prefix back over the prefix's own audio; that reading is
    /// dropped, so the confirmed words are never doubled and agreement starts at
    /// the first word after the prefix.
    @Test func thePrefixReReadingIsDropped() {
        var hearing = Self.hearing()
        hearing.hear([Self.word(" a", 0, 0.1), Self.word(" b", 0.2, 0.3), Self.word(" c", 0.4, 0.5)], through: Self.samples(2))
        hearing.hear([Self.word(" a", 0, 0.1), Self.word(" b", 0.2, 0.3), Self.word(" c", 0.4, 0.5)], through: Self.samples(3))
        #expect(hearing.confirmed.map(\.text) == [" a", " b", " c"])
        hearing.hear([Self.word(" a", 0, 0.1), Self.word(" b", 0.2, 0.3), Self.word(" c", 0.4, 0.5), Self.word(" d", 2.0, 2.3)], through: Self.samples(3.5))
        #expect(hearing.confirmed.map(\.text) == [" a", " b", " c"])
        #expect(hearing.tentative.map(\.text) == [" d"])
        hearing.hear([Self.word(" a", 0, 0.1), Self.word(" b", 0.2, 0.3), Self.word(" c", 0.4, 0.5), Self.word(" d", 2.0, 2.3)], through: Self.samples(4))
        #expect(hearing.confirmed.map(\.text) == [" a", " b", " c", " d"])
        #expect(hearing.partial.text == " a b c d")
    }

    /// The prefix is said without its final punctuation, and its words are dropped
    /// whether they come back with their punctuation or without it.
    @Test func thePrefixIsSaidWithoutItsFinalPunctuation() {
        var hearing = Self.hearing()
        let words = [Self.word(" Hi", 0, 0.1), Self.word(" there!'", 0.2, 0.3), Self.word(" hissed", 0.4, 0.5), Self.word(" Lumpy,", 0.6, 0.7)]
        hearing.hear(words, through: Self.samples(2))
        hearing.hear(words, through: Self.samples(3))
        #expect(hearing.confirmed.map(\.text) == [" Hi", " there!'", " hissed", " Lumpy,"])
        #expect(hearing.saying == " there!' hissed Lumpy")
        hearing.hear([Self.word(" there!'", 0.2, 0.3), Self.word(" hissed", 0.4, 0.5), Self.word(" Lumpy", 0.6, 0.7), Self.word(" filled", 2.5, 2.8)], through: Self.samples(3.5))
        #expect(hearing.tentative.map(\.text) == [" filled"])
        #expect(hearing.partial.text == " Hi there!' hissed Lumpy, filled")
    }

    /// A prefix read differently is not the prefix: it stays in the reading, visible
    /// next to the confirmed words, rather than vanishing as if it had matched.
    @Test func aDifferentlyReadPrefixStaysVisible() {
        var hearing = Self.hearing()
        hearing.hear([Self.word(" a", 0, 0.1), Self.word(" b", 0.2, 0.3)], through: Self.samples(2))
        hearing.hear([Self.word(" a", 0, 0.1), Self.word(" b", 0.2, 0.3)], through: Self.samples(3))
        hearing.hear([Self.word(" a", 0, 0.1), Self.word(" uh", 0.2, 0.3), Self.word(" c", 2.5, 2.8)], through: Self.samples(4))
        #expect(hearing.confirmed.map(\.text) == [" a", " b"])
        #expect(hearing.tentative.map(\.text) == [" uh", " c"])
        #expect(hearing.partial.text == " a b uh c")
    }

    /// Once nothing more comes, the last reading is the transcript: confirmed
    /// words, then the last pass's words after its prefix.
    @Test func theTranscriptIsConfirmedThenTentative() {
        var hearing = Self.hearing()
        hearing.hear([Self.word(" a", 0, 0.1), Self.word(" b", 0.2, 0.3)], through: Self.samples(2))
        hearing.hear([Self.word(" a", 0, 0.1), Self.word(" b", 0.2, 0.3)], through: Self.samples(3))
        hearing.hear([Self.word(" a", 0, 0.1), Self.word(" b", 0.2, 0.3), Self.word(" c", 2.5, 2.8)], through: Self.samples(4))
        #expect(hearing.transcript.text == " a b c")
    }
}
