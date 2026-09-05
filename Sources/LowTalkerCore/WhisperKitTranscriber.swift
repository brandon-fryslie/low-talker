import Foundation
import WhisperKit

/// Whisper on the Neural Engine through WhisperKit, decoding a whole clip at once.
///
/// [LAW:no-shared-mutable-globals] WhisperKit's pipeline is a mutable class that is
/// not Sendable and not safe to re-enter mid-decode. The actor is its one owner:
/// every call queues behind the one in flight, and nothing else can reach it.
public actor WhisperKitTranscriber: Transcriber {
    public let model: Model
    /// `nonisolated(unsafe)` because WhisperKit's async methods run off the actor and
    /// the compiler cannot see that the actor serializes every call to them. The
    /// property is private, so the actor's methods are the only callers.
    nonisolated(unsafe) private let pipeline: WhisperKit

    /// Word timings are the whole point: without them a result carries no per-word
    /// confidence and the mapping below refuses it.
    private static let decodeOptions = DecodingOptions(wordTimestamps: true)

    /// Downloads the model into WhisperKit's cache on first use, then loads it onto
    /// the compute units. Returns only once the model is resident, so the first
    /// `transcribe` pays no load cost.
    public init(model: Model = .default) async throws {
        self.model = model
        // WhisperKit logs to stdout when verbose; stdout belongs to whoever called us.
        pipeline = try await WhisperKit(WhisperKitConfig(model: model.rawValue, verbose: false, load: true))
    }

    public func transcribe(_ clip: AudioClip) async throws -> Transcript {
        let results = try await pipeline.transcribe(audioArray: clip.samples, decodeOptions: Self.decodeOptions)
        return try Transcript(whisperKit: results.flatMap(\.segments))
    }

    /// A model folder name in the whisperkit-coreml repo, such as `base.en` or
    /// `large-v3-v20240930_626MB`. The repo grows, so this is a name, not an enum.
    public struct Model: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            self.init(rawValue: value)
        }

        public var description: String { rawValue }

        /// Whisper large-v3-turbo: large-v3's encoder with a four-layer decoder, so it
        /// keeps the accuracy while decoding several times faster. The default until
        /// the latency harness measures the candidates on real hardware.
        public static let `default`: Model = "large-v3-v20240930_626MB"
    }
}

public enum WhisperKitTranscriberError: Error, CustomStringConvertible {
    /// WhisperKit returned a segment with no word timings, which it only does when
    /// decoding ran without `wordTimestamps`.
    case segmentWithoutWords(text: String)
    case probabilityOutsideUnitInterval(WordTiming)
    case wordEndsBeforeStart(WordTiming)

    public var description: String {
        switch self {
        case .segmentWithoutWords(let text):
            "WhisperKit returned segment \"\(text)\" without word timings"
        case .probabilityOutsideUnitInterval(let word):
            "WhisperKit gave word \"\(word.word)\" probability \(word.probability), outside \(Confidence.range)"
        case .wordEndsBeforeStart(let word):
            "WhisperKit gave word \"\(word.word)\" end \(word.end) before start \(word.start)"
        }
    }
}

extension Transcript {
    /// The words of every segment, in order, as WhisperKit emitted them: each word
    /// carries its own leading space and trailing punctuation, which is exactly the
    /// convention `Transcript.text` relies on.
    ///
    /// [LAW:parse-dont-validate] WhisperKit's optional word list and unbounded floats
    /// become non-optional words, a ClosedRange, and a Confidence here, once. Anything
    /// that does not fit is refused loudly rather than clamped.
    public init(whisperKit segments: [TranscriptionSegment]) throws {
        self.init(words: try segments.flatMap { segment in
            guard let words = segment.words else {
                throw WhisperKitTranscriberError.segmentWithoutWords(text: segment.text)
            }
            return try words.map(Word.init(whisperKit:))
        })
    }
}

extension Transcript.Word {
    public init(whisperKit timing: WordTiming) throws {
        guard let confidence = Confidence(exactly: Double(timing.probability)) else {
            throw WhisperKitTranscriberError.probabilityOutsideUnitInterval(timing)
        }
        guard timing.start <= timing.end else {
            throw WhisperKitTranscriberError.wordEndsBeforeStart(timing)
        }
        self.init(text: timing.word, time: Double(timing.start)...Double(timing.end), confidence: confidence)
    }
}
