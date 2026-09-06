import Foundation
import WhisperKit

/// Whisper on the Neural Engine through WhisperKit.
///
/// [LAW:no-shared-mutable-globals] WhisperKit's pipeline is a mutable class that must
/// not be re-entered mid-decode. Every decode goes through one SerialQueue, so calls
/// queue rather than overlap, and nothing else can reach the pipeline.
public final class WhisperKitTranscriber: Transcriber {
    public let model: ModelName
    private let pipeline: Pipeline
    private let decodes = SerialQueue()

    /// Loads an installed model onto the compute units, its weights from disk alone.
    /// Returns only once the model is resident, so the first `transcribe` pays no
    /// load cost.
    public init(_ installed: InstalledModel) async throws {
        model = installed.model
        pipeline = try await Pipeline(installed: installed)
    }

    /// The whole road from a store to a resident model: the store installs whatever
    /// it lacks, then the model is loaded. `phase` hears each step begin so a status
    /// item or a terminal can say what the wait is for.
    public static func load(
        _ model: ModelName = .default,
        from store: ModelStore,
        phase: @escaping @Sendable (LoadPhase) -> Void
    ) async throws -> WhisperKitTranscriber {
        let installed = try await store.install(model) { phase(.installing($0)) }
        phase(.loading)
        return try await WhisperKitTranscriber(installed)
    }

    /// What `load(_:from:phase:)` is doing right now. There is no "ready" case: the
    /// returned transcriber is that state.
    public enum LoadPhase: Equatable, Sendable, CustomStringConvertible {
        case installing(ModelStore.InstallPhase)
        /// Core ML is loading the model. The first load after an install also fetches
        /// the tokenizer when `tokenizer.json` is not in the hub yet; the first on a
        /// Mac, after an OS update, or after a change to the app's signing identity
        /// also specializes the model for the Neural Engine, which takes minutes.
        case loading

        public var description: String {
            switch self {
            case .installing(let phase): phase.description
            case .loading: "loading model"
            }
        }
    }

    /// Hears the utterance in passes as its audio arrives. Whisper decodes a whole
    /// window at a time, so streaming is re-reading: each pass decodes from a few
    /// confirmed words back to the audio so far, and words two passes agree on are
    /// confirmed and never read again. A pass runs whenever the engine is free and
    /// speech has arrived since the last one, so the partials are as fresh as the
    /// engine allows; the pass that covers the last of the speech is the last pass,
    /// whether the key is still down when it starts or has already come up.
    public func transcribe(
        _ audio: some AsyncSequence<AudioClip, Never> & Sendable,
        expecting vocabulary: Vocabulary,
        partial: @escaping @Sendable (Partial) -> Void
    ) async throws -> Transcript {
        let pipeline = pipeline
        // The vocabulary is encoded once and refused, if it must be, before any
        // audio is taken in, so a hold never gets as far as the gate with a prompt
        // the engine cannot carry.
        let prompt = try await decodes.run { try pipeline.prompt(for: vocabulary) }
        let utterance = Utterance()
        async let fed: Void = utterance.fill(from: audio)
        var hearing = Hearing(margin: Pipeline.margin, context: Pipeline.contextWords)
        // [LAW:dataflow-not-control-flow] The one branch is the utterance's own state:
        // speech to hear, or nothing more. A pass over what is there is the same pass
        // whether the key is still down or just came up, and the last pass's reading
        // is the transcript once no speech follows it. During the hold a pass waits
        // for speech worth one; once the utterance has ended, whatever speech no pass
        // has heard gets the last pass, however short, and the pipeline pads it out
        // to the engine's floor. So a tap-to-toggle "yes" is heard, not decoded as
        // nothing, and a hold with nothing said in it is still no pass at all.
        while case let (samples, ended) = await utterance.audio(beyond: hearing.passable), samples.count > hearing.heard {
            let (cut, saying) = (hearing.cut, hearing.saying)
            let words = try await decodes.run { try await pipeline.hear(samples, from: cut, saying: saying, told: prompt) }
            hearing.hear(words, through: samples.count)
            if ended { break }
            partial(hearing.partial)
        }
        try await fed
        return hearing.transcript
    }

    /// The loaded WhisperKit pipeline. `@unchecked Sendable` because WhisperKit is a
    /// mutable class the compiler cannot vouch for; the SerialQueue is what keeps
    /// every decode alone with it. Internal, not private, so the tests can reach the
    /// windowing arithmetic without a model.
    struct Pipeline: @unchecked Sendable {
        private let whisperKit: WhisperKit
        private let tokenizer: any WhisperTokenizer

        /// Word timings are the whole point: without them a result carries no per-word
        /// confidence and the mapping refuses it. A segment's text is its words alone:
        /// with the special tokens left in, a pass that heard nothing comes back as
        /// "<|startoftranscript|><|en|>...<|endoftext|>" with no words, which the
        /// mapping would rightly refuse as speech that lost its words.
        private static let decodeOptions = DecodingOptions(skipSpecialTokens: true, wordTimestamps: true)

        /// [LAW:one-source-of-truth] WhisperKit decodes no window that starts within
        /// `windowClipTime` of the clip's end, its guard against hallucinating over a
        /// trailing sliver. A word is confirmed only when it ended this far before the
        /// pass's end, so the next pass, starting at that word, always spans more; and
        /// a pass over less than this from its cut, the whole of an utterance shorter
        /// than a second, is padded out past it by `window(_:from:)`.
        static let margin = AudioClip.sampleCount(for: Double(decodeOptions.windowClipTime))

        /// The audio a pass reads: `samples`, run out with silence to one sample more
        /// than `margin` past `cut` when they fall short of it, so the engine's guard
        /// sees a window it will decode. Silence after the speech is what the encoder
        /// pads every window with anyway, so the reading is the same as the guard
        /// would have given a longer clip; and audio already past the floor is
        /// untouched, so a real trailing sliver is still refused as it was.
        ///
        /// [LAW:effects-at-boundaries] Pure, so the arithmetic is tested without a
        /// model; `hear` is the effect that reads what this returns.
        static func window(_ samples: [Float], from cut: Int) -> [Float] {
            samples + Array(repeating: 0, count: max(0, cut + margin + 1 - samples.count))
        }

        /// Confirmed words a pass starts from, forced as its first tokens rather than
        /// prompted as earlier text: a prompt is decoded against audio that no longer
        /// holds it, and Whisper then reads the prompted words a second time out of
        /// the audio that follows, so the prefix is forced over the audio that does
        /// hold it and its reading is dropped. Each forced token costs a decoder step,
        /// the same as decoding it, so the prefix is a few words, not every confirmed one.
        static let contextWords = 3

        /// Nonisolated on purpose: the non-Sendable WhisperKit is created and wrapped
        /// here without crossing an isolation boundary.
        nonisolated init(installed: InstalledModel) async throws {
            // WhisperKit logs to stdout when verbose; stdout belongs to whoever called us.
            // `download` gates only the weights, which `modelFolder` supplies; the
            // tokenizer is read from `tokenizerFolder`, fetched into it when absent.
            // The seeker is ours so that a prompted pass keeps its word timings.
            whisperKit = try await WhisperKit(WhisperKitConfig(
                modelFolder: installed.folder.path,
                tokenizerFolder: installed.hub,
                segmentSeeker: PromptOffsetSegmentSeeker(),
                verbose: false,
                load: true,
                download: false
            ))
            // [LAW:parse-dont-validate] WhisperKit loads its tokenizer with the model
            // and holds it as an optional; it is unwrapped here, once, so every pass
            // has one to encode its prefix with.
            guard let tokenizer = whisperKit.tokenizer else {
                throw WhisperKitTranscriberError.tokenizerNotLoaded(installed.model)
            }
            self.tokenizer = tokenizer
        }

        /// The vocabulary as the decoder's prompt: the text of a segment before the
        /// utterance, which is how Whisper is told spellings it could not guess.
        /// Told " Brynleigh Fryslie" and then hearing the names, it writes them so
        /// rather than "Brynley Frisley". The prompt stands before the start of the
        /// transcript and the forced prefix after it, so one pass carries both. A
        /// prompt is decoded against audio that does not hold it, and Whisper will
        /// read prompted words a second time out of the audio that follows when
        /// they were the words just heard; a list of terms is not, which is why the
        /// vocabulary goes here and the confirmed words go in the prefix.
        ///
        /// [LAW:no-silent-failure] A vocabulary past WhisperKit's prompt limit is
        /// refused with its size, where WhisperKit would keep the last of it and say
        /// nothing, losing the first terms without a word said. The count is of the
        /// tokens WhisperKit would keep, its special tokens filtered out as its
        /// decoder does. Every prompt token also takes one of the decoder steps a
        /// window has (`Constants.maxTokenContext` less one, prefill included), so a
        /// long vocabulary leaves a 30 s window fewer words to read.
        func prompt(for vocabulary: Vocabulary) throws -> [Int] {
            let tokens = tokenizer.encode(text: vocabulary.whisperPrompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            let limit = PromptOffsetSegmentSeeker.promptTokenLimit
            guard tokens.count <= limit else {
                throw WhisperKitTranscriberError.vocabularyTooLong(tokens: tokens.count, limit: limit)
            }
            return tokens
        }

        /// One pass: the words in `samples` from `cut` on, the first of them forced to
        /// read `prefix`, the text spoken from the cut, with `prompt` as the text
        /// before the utterance. Times are from the utterance's start, and the
        /// prefix's words come back first, timed over their own audio. Samples short
        /// of the engine's floor are padded out to it; see `window(_:from:)`.
        func hear(_ samples: [Float], from cut: Int, saying prefix: String, told prompt: [Int]) async throws -> [Transcript.Word] {
            var options = Self.decodeOptions
            options.clipTimestamps = [Float(AudioClip.duration(for: cut))]
            options.promptTokens = prompt
            options.prefixTokens = tokenizer.encode(text: prefix)
            let results = try await whisperKit.transcribe(audioArray: Self.window(samples, from: cut), decodeOptions: options)
            return try Transcript(whisperKit: results.flatMap(\.segments)).words
        }
    }
}

public enum WhisperKitTranscriberError: Error, CustomStringConvertible {
    /// WhisperKit returned a segment with speech in its text but no word timings to
    /// carry it, so the text would be lost.
    case speechWithoutWords(text: String)
    case probabilityOutsideUnitInterval(WordTiming)
    case wordEndsBeforeStart(WordTiming)
    /// WhisperKit loaded the model but holds no tokenizer for it.
    case tokenizerNotLoaded(ModelName)
    /// The vocabulary encodes to more prompt tokens than WhisperKit keeps.
    case vocabularyTooLong(tokens: Int, limit: Int)

    public var description: String {
        switch self {
        case .tokenizerNotLoaded(let model):
            "WhisperKit loaded \(model) without its tokenizer"
        case .vocabularyTooLong(let tokens, let limit):
            "the vocabulary is \(tokens) prompt tokens and WhisperKit keeps at most \(limit)"
        case .speechWithoutWords(let text):
            "WhisperKit returned segment \"\(text)\" without word timings"
        case .probabilityOutsideUnitInterval(let word):
            "WhisperKit gave word \"\(word.word)\" probability \(word.probability), outside \(Confidence.range)"
        case .wordEndsBeforeStart(let word):
            "WhisperKit gave word \"\(word.word)\" end \(word.end) before start \(word.start)"
        }
    }
}

extension Vocabulary {
    /// The terms as the text of a segment said before the utterance: each with the
    /// leading space a spoken word carries and nothing between them, so
    /// " Brynleigh Fryslie Jaxxon". Commas between the terms read back into the
    /// transcript: told " Brynleigh, Fryslie", Whisper wrote "Brynleigh," for the
    /// name spoken mid-sentence, while the bare list biased the same names as well
    /// or better and punctuated nothing. No terms is no text and so no prompt at
    /// all, which is what WhisperKit makes of no tokens; a prompt of nothing but
    /// its start token leans the decoder toward ending the segment early.
    var whisperPrompt: String {
        terms.map { " " + $0.text }.joined()
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
