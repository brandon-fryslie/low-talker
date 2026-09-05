import Foundation

/// What the engine heard, word by word. Never a bare string: timings and confidence
/// are what let a route trust, trim, or reject what was said.
///
/// [LAW:one-source-of-truth] The words are the transcript; `text` is derived from them
/// so the two can never disagree.
public struct Transcript: Hashable, Codable, Sendable {
    public let words: [Word]

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
        public let text: String
        /// Seconds from the start of the clip. A ClosedRange makes an end before a
        /// start unrepresentable.
        public let time: ClosedRange<TimeInterval>
        public let confidence: Confidence

        public init(text: String, time: ClosedRange<TimeInterval>, confidence: Confidence) {
            self.text = text
            self.time = time
            self.confidence = confidence
        }
    }
}

/// An engine's probability for a word, 0 through 1. Values outside that range do not
/// exist: a literal outside it is a programmer error, a runtime value outside it is
/// nil, and decoded input outside it is refused.
public struct Confidence: Hashable, Codable, Sendable, Comparable, ExpressibleByFloatLiteral {
    public static let range: ClosedRange<Double> = 0...1

    public let value: Double

    public init?(exactly value: Double) {
        guard Self.range.contains(value) else { return nil }
        self.value = value
    }

    public init(floatLiteral value: Double) {
        precondition(Self.range.contains(value), "confidence \(value) is outside \(Self.range)")
        self.value = value
    }

    /// [LAW:parse-dont-validate] Decoded as a bare number; refused here, once, so no
    /// consumer re-checks the range.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Double.self)
        guard let confidence = Self(exactly: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "confidence \(value) is outside \(Self.range)")
        }
        self = confidence
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }
}
