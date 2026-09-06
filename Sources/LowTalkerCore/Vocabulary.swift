import Foundation

/// What the speaker is expected to say that an engine could not guess the
/// spelling of: names, jargon, and in command mode the app names and keywords.
/// Each mode supplies one, and the engine is told it before the utterance begins,
/// so a small vocabulary matched against a biased transcript takes the place of
/// spotting keywords in open speech.
///
/// [LAW:types-are-the-program] A vocabulary is a list of terms and nothing else:
/// no flag for whether to use it, since the empty one is the one to use when
/// nothing beyond ordinary speech is expected.
public struct Vocabulary: Hashable, Sendable {
    public let terms: [Term]

    public init(_ terms: [Term]) {
        self.terms = terms
    }

    /// Nothing expected beyond ordinary speech.
    public static let empty = Vocabulary([])

    /// One thing the speaker may say, spelled as it should be written. The
    /// spelling and case are kept as given; they are the point.
    ///
    /// [LAW:parse-dont-validate] A term in hand can be said: it has a word in it
    /// by the same rule that scores hearing, so an engine is never handed a blank
    /// entry to prompt with, and the surrounding whitespace is gone.
    public struct Term: Hashable, Sendable, CustomStringConvertible {
        public let text: String

        public init(_ text: String) throws {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !SpokenWords(trimmed).words.isEmpty else { throw VocabularyError.termSaysNothing(text) }
            self.text = trimmed
        }

        public var description: String { text }
    }
}

public enum VocabularyError: Error, Equatable, CustomStringConvertible {
    /// A term with no word in it: blank, or punctuation alone.
    case termSaysNothing(String)

    public var description: String {
        switch self {
        case .termSaysNothing(let text):
            "vocabulary term \"\(text)\" has no word in it"
        }
    }
}
