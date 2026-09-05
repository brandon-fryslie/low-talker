import Foundation

/// The words of an utterance as hearing is scored: lowercased, with case and
/// punctuation gone, so "Hello, world." and " hello world" are the same speech.
/// Punctuation and capitals are the engine's guess at typography; the harness
/// scores what it heard.
///
/// [LAW:single-enforcer] The one rule that turns text into comparable words, applied
/// to reference and hypothesis alike, so a fixture author's spelling and an
/// engine's cannot be scored by different rules.
public struct SpokenWords: Hashable, Sendable {
    public let words: [String]

    /// Words are runs of letters, digits, and apostrophes; anything else separates.
    /// Hyphens separate too, so "push-to-talk" and "push to talk" agree. An
    /// apostrophe inside a word is a contraction and stays; at either edge it is a
    /// quotation mark and goes, so "'Hi there!'" is hi and there.
    public init(_ text: String) {
        words = text
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }
}

/// How far an engine's hearing fell from what was said, as the edits that turn the
/// hypothesis back into the reference, counted in words.
public struct WordErrorRate: Hashable, Sendable, CustomStringConvertible {
    public let substitutions: Int
    public let deletions: Int
    public let insertions: Int
    public let referenceCount: Int

    public var errors: Int { substitutions + deletions + insertions }

    /// Errors per reference word. Above 1 is possible when the engine heard more
    /// words than were said.
    public var rate: Double { Double(errors) / Double(referenceCount) }

    /// The fewest edits between the two word lists. When several edit paths tie,
    /// substitution is preferred to a deletion, and a deletion to an insertion, so
    /// the split of a given count is deterministic.
    ///
    /// `reference` must contain a word: a rate over nothing said is not a number.
    /// `Fixture` is the checkpoint that keeps such a reference from reaching here.
    public init(reference: SpokenWords, hypothesis: SpokenWords) {
        precondition(!reference.words.isEmpty, "a word error rate needs at least one reference word")
        let reference = reference.words
        let hypothesis = hypothesis.words
        // Cell (i, j) holds the cheapest edits between the first i reference words and
        // the first j hypothesis words; carrying the split in every cell removes the
        // need to walk back through the table afterwards.
        var row = (0...hypothesis.count).map { Edits(substitutions: 0, deletions: 0, insertions: $0) }
        for (i, said) in reference.enumerated() {
            var next = [Edits(substitutions: 0, deletions: i + 1, insertions: 0)]
            for (j, heard) in hypothesis.enumerated() {
                let matched = said == heard ? row[j] : row[j].adding(substitutions: 1)
                let deleted = row[j + 1].adding(deletions: 1)
                let inserted = next[j].adding(insertions: 1)
                next.append([matched, deleted, inserted].min { $0.total < $1.total }!)
            }
            row = next
        }
        let edits = row[hypothesis.count]
        substitutions = edits.substitutions
        deletions = edits.deletions
        insertions = edits.insertions
        referenceCount = reference.count
    }

    private struct Edits {
        var substitutions: Int
        var deletions: Int
        var insertions: Int
        var total: Int { substitutions + deletions + insertions }

        func adding(substitutions: Int = 0, deletions: Int = 0, insertions: Int = 0) -> Edits {
            Edits(substitutions: self.substitutions + substitutions, deletions: self.deletions + deletions, insertions: self.insertions + insertions)
        }
    }

    public var description: String {
        "\(errors)/\(referenceCount) (\(substitutions) substituted, \(deletions) dropped, \(insertions) added)"
    }
}
