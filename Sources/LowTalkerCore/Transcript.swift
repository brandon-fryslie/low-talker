import Foundation

/// What the engine heard, word by word. Never a bare string: timings and confidence
/// are what let a route trust, trim, or reject what was said.
///
/// [LAW:one-source-of-truth] The words are the transcript; `text` is derived from them
/// so the two can never disagree.
public struct Transcript: Hashable, Codable, Sendable {
    public var words: [Word]

    public init(words: [Word]) {
        self.words = words
    }

    /// The words concatenated as the engine emitted them. Each word carries its own
    /// leading whitespace and trailing punctuation, so concatenation reproduces the
    /// utterance exactly.
    public var text: String {
        words.map(\.text).joined()
    }

    public struct Word: Hashable, Codable, Sendable {
        public var text: String
        /// Seconds from the start of the clip. A ClosedRange makes an end before a
        /// start unrepresentable.
        public var time: ClosedRange<TimeInterval>
        /// The engine's probability for this word, 0 through 1.
        public var confidence: Double

        public init(text: String, time: ClosedRange<TimeInterval>, confidence: Double) {
            self.text = text
            self.time = time
            self.confidence = confidence
        }
    }
}
