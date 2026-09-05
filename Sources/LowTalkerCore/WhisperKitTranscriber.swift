import Foundation
import WhisperKit

/// Whisper on the Neural Engine through WhisperKit, decoding a whole clip at once.
///
/// [LAW:no-shared-mutable-globals] WhisperKit's pipeline is a mutable class that must
/// not be re-entered mid-decode. Every decode goes through one SerialQueue, so calls
/// queue rather than overlap, and nothing else can reach the pipeline.
public final class WhisperKitTranscriber: Transcriber {
    public let model: Model
    private let pipeline: Pipeline
    private let decodes = SerialQueue()

    /// Downloads the model into WhisperKit's cache on first use, then loads it onto
    /// the compute units. Returns only once the model is resident, so the first
    /// `transcribe` pays no load cost.
    public init(model: Model = .default) async throws {
        self.model = model
        pipeline = try await Pipeline(model: model)
    }

    public func transcribe(_ clip: AudioClip) async throws -> Transcript {
        let pipeline = pipeline
        return try await decodes.run { try await pipeline.transcribe(clip) }
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

    /// The loaded WhisperKit pipeline. `@unchecked Sendable` because WhisperKit is a
    /// mutable class the compiler cannot vouch for; the SerialQueue is what keeps
    /// every decode alone with it.
    private struct Pipeline: @unchecked Sendable {
        private let whisperKit: WhisperKit

        /// Word timings are the whole point: without them a result carries no per-word
        /// confidence and the mapping refuses it.
        private static let decodeOptions = DecodingOptions(wordTimestamps: true)

        /// Nonisolated on purpose: the non-Sendable WhisperKit is created and wrapped
        /// here without crossing an isolation boundary.
        nonisolated init(model: Model) async throws {
            // WhisperKit logs to stdout when verbose; stdout belongs to whoever called us.
            whisperKit = try await WhisperKit(WhisperKitConfig(model: model.rawValue, verbose: false, load: true))
        }

        func transcribe(_ clip: AudioClip) async throws -> Transcript {
            let results = try await whisperKit.transcribe(audioArray: clip.samples, decodeOptions: Self.decodeOptions)
            return try Transcript(whisperKit: results.flatMap(\.segments))
        }
    }
}

public enum WhisperKitTranscriberError: Error, CustomStringConvertible {
    /// WhisperKit returned a segment with speech in its text but no word timings to
    /// carry it, so the text would be lost.
    case speechWithoutWords(text: String)
    case probabilityOutsideUnitInterval(WordTiming)
    case wordEndsBeforeStart(WordTiming)

    public var description: String {
        switch self {
        case .speechWithoutWords(let text):
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
    /// that does not fit is refused loudly rather than clamped, including a segment
    /// whose speech has no words to carry it: the words are the transcript, so speech
    /// with no words would simply vanish.
    public init(whisperKit segments: [TranscriptionSegment]) throws {
        self.init(words: try segments.flatMap { segment in
            let words = segment.words ?? []
            guard !words.isEmpty || !segment.text.contains(where: { !$0.isWhitespace }) else {
                throw WhisperKitTranscriberError.speechWithoutWords(text: segment.text)
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
