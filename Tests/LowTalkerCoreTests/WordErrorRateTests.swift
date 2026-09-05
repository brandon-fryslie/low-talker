import LowTalkerCore
import Testing

@Suite struct SpokenWordsTests {
    /// Case, punctuation, and the whitespace WhisperKit leads each word with are
    /// typography, not hearing.
    @Test func typographyIsNotSpeech() {
        #expect(SpokenWords(" Hello, world!").words == ["hello", "world"])
        #expect(SpokenWords("hello world").words == ["hello", "world"])
    }

    @Test func hyphensSeparateAndApostrophesJoin() {
        #expect(SpokenWords("push-to-talk").words == ["push", "to", "talk"])
        #expect(SpokenWords("don\u{2019}t don't").words == ["don't", "don't"])
    }

    /// An apostrophe at a word's edge is a quotation mark, not speech.
    @Test func quotationApostrophesAreNotWords() {
        #expect(SpokenWords("\"'Hi there!' hissed Lumpy. 'What's that?'").words == ["hi", "there", "hissed", "lumpy", "what's", "that"])
        #expect(SpokenWords("' ''").words.isEmpty)
    }

    @Test func nothingSaidIsNoWords() {
        #expect(SpokenWords(" ... ").words.isEmpty)
    }
}

@Suite struct WordErrorRateTests {
    static func rate(_ reference: String, _ hypothesis: String) -> WordErrorRate {
        WordErrorRate(reference: SpokenWords(reference), hypothesis: SpokenWords(hypothesis))
    }

    @Test func hearingItRightIsZero() {
        let wer = Self.rate("Hello world, this is low talker.", " hello world this is Low Talker")
        #expect(wer.errors == 0)
        #expect(wer.rate == 0)
        #expect(wer.referenceCount == 6)
    }

    @Test func eachKindOfEditIsCountedApart() {
        let wer = Self.rate("see you at noon", "see me at")
        #expect(wer.substitutions == 1)
        #expect(wer.deletions == 1)
        #expect(wer.insertions == 0)
        #expect(wer.rate == 0.5)

        let added = Self.rate("see you", "see you soon")
        #expect(added.insertions == 1)
        #expect(added.errors == 1)
    }

    /// The cheapest path is taken, not the first one found: a dropped word early on
    /// costs one edit, not a substitution of every word after it.
    @Test func editsAreTheFewestPossible() {
        let wer = Self.rate("the event tap toggles listening", "event tap toggles listening")
        #expect(wer.deletions == 1)
        #expect(wer.substitutions == 0)
    }

    @Test func hearingNothingDropsEveryWord() {
        let wer = Self.rate("one two three", "")
        #expect(wer.deletions == 3)
        #expect(wer.rate == 1)
    }

    @Test func hearingTooMuchExceedsOne() {
        #expect(Self.rate("yes", "yes yes yes").rate == 2)
    }
}
