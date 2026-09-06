@testable import LowTalkerCore
import Testing
import WhisperKit

/// The mapping from WhisperKit's result types onto Transcript, exercised with
/// hand-built results so it runs where no model weights exist. The real engine is
/// exercised by `lowtalker transcribe` on a Mac that has the weights.
@Suite struct WhisperKitTranscriberTests {
    static func word(_ text: String, _ start: Float, _ end: Float, _ probability: Float) -> WordTiming {
        WordTiming(word: text, tokens: [0], start: start, end: end, probability: probability)
    }

    /// Words keep their order across segments and arrive as WhisperKit spelled them:
    /// leading space and trailing punctuation attached.
    @Test func wordsAcrossSegmentsBecomeTheTranscript() throws {
        let segments = [
            TranscriptionSegment(start: 0, end: 1, text: " Hello world,", words: [
                Self.word(" Hello", 0.10, 0.42, 0.98),
                Self.word(" world,", 0.50, 0.91, 0.87),
            ]),
            TranscriptionSegment(start: 1, end: 2, text: " again.", words: [
                Self.word(" again.", 1.20, 1.60, 0.75),
            ]),
        ]
        let transcript = try Transcript(whisperKit: segments)
        #expect(transcript.words.map(\.text) == [" Hello", " world,", " again."])
        #expect(transcript.text == " Hello world, again.")
        // WhisperKit's numbers are Float and the mapping widens them exactly, so the
        // expectations are Float literals widened the same way; a Double literal 0.42
        // is not the number Float 0.42 denotes.
        let probabilities: [Float] = [0.98, 0.87, 0.75]
        let times: [ClosedRange<Float>] = [0.10...0.42, 0.50...0.91, 1.20...1.60]
        #expect(transcript.words.map(\.confidence.value) == probabilities.map(Double.init))
        #expect(transcript.words.map(\.time) == times.map { Double($0.lowerBound)...Double($0.upperBound) })
    }

    @Test func noSegmentsIsAnEmptyTranscript() throws {
        #expect(try Transcript(whisperKit: []).words.isEmpty)
    }

    /// A word that starts and ends on the same instant is a legal, empty range.
    @Test func instantaneousWordIsLegal() throws {
        let word = try Transcript.Word(whisperKit: Self.word(" hi", 1.5, 1.5, 1))
        #expect(word.time == 1.5...1.5)
    }

    /// Speech with no words to carry it would vanish from the transcript, so the
    /// mapping refuses it, whether the word list is missing or merely empty.
    @Test(arguments: [nil, [WordTiming]()])
    func speechWithoutWordTimingsIsRefused(words: [WordTiming]?) {
        let segment = TranscriptionSegment(text: " Hello", words: words)
        #expect(throws: WhisperKitTranscriberError.self) {
            try Transcript(whisperKit: [segment])
        }
    }

    /// A segment that said nothing has nothing to lose; it contributes no words.
    @Test(arguments: [nil, [WordTiming]()])
    func silentSegmentWithoutWordTimingsIsNothingSaid(words: [WordTiming]?) throws {
        let segment = TranscriptionSegment(text: " ", words: words)
        #expect(try Transcript(whisperKit: [segment]).words.isEmpty)
    }

    @Test(arguments: [Float(1.01), Float(-0.01)])
    func probabilityOutsideUnitIntervalIsRefused(probability: Float) {
        #expect(throws: WhisperKitTranscriberError.self) {
            try Transcript.Word(whisperKit: Self.word(" hi", 0, 1, probability))
        }
    }

    @Test func wordEndingBeforeStartIsRefused() {
        #expect(throws: WhisperKitTranscriberError.self) {
            try Transcript.Word(whisperKit: Self.word(" hi", 1.0, 0.5, 1))
        }
    }

    /// WhisperKit decodes no window unless it spans more than `windowClipTime` past
    /// its start, so a pass over less is run out with silence to one sample past
    /// that floor, and the speech in it is untouched.
    @Test func aPassShorterThanTheFloorIsPaddedOutPastIt() {
        let margin = WhisperKitTranscriber.Pipeline.margin
        let speech = Array(repeating: Float(0.5), count: 6_400)
        let window = WhisperKitTranscriber.Pipeline.window(speech, from: 0)
        #expect(margin == AudioClip.sampleCount(for: 1))
        #expect(window.count == margin + 1)
        #expect(window.prefix(6_400).allSatisfy { $0 == 0.5 })
        #expect(window.dropFirst(6_400).allSatisfy { $0 == 0 })
    }

    /// The floor is measured from the cut, not from the utterance's start: a pass
    /// that starts late in the audio is padded so that its own span clears it.
    @Test func theFloorIsMeasuredFromTheCut() {
        let margin = WhisperKitTranscriber.Pipeline.margin
        let audio = Array(repeating: Float(0.5), count: 40_000)
        #expect(WhisperKitTranscriber.Pipeline.window(audio, from: 30_000).count == 30_000 + margin + 1)
    }

    /// Audio already past the floor is handed over as it is, so the engine's guard
    /// against a trailing sliver still sees the clip it would have seen.
    @Test(arguments: [0, 8_000])
    func aPassPastTheFloorIsUntouched(cut: Int) {
        let audio = Array(repeating: Float(0.5), count: 40_000)
        #expect(WhisperKitTranscriber.Pipeline.window(audio, from: cut) == audio)
    }

    /// A pass is one decode: no temperature rung to climb, and so no first-token
    /// abort either, since that abort exists to reach the next rung sooner and with
    /// none to reach it would return a single token as the whole reading.
    @Test func aPassIsOneDecodeWithNothingToFallBackTo() {
        let options = WhisperKitTranscriber.Pipeline.decodeOptions
        #expect(options.temperatureFallbackCount == 0)
        #expect(options.firstTokenLogProbThreshold == nil)
        #expect(options.temperature == 0)
    }

    /// The prompt is the terms as spoken text: each with its leading space and no
    /// punctuation to read back, and nothing at all for no terms, so an empty
    /// vocabulary encodes to no tokens and WhisperKit prompts with nothing.
    @Test func theVocabularyPromptIsTheTermsAsEarlierText() throws {
        let vocabulary = Vocabulary([try Vocabulary.Term("Brynleigh"), try Vocabulary.Term("Fryslie"), try Vocabulary.Term("pull request")])
        #expect(vocabulary.whisperPrompt == " Brynleigh Fryslie pull request")
        #expect(Vocabulary.empty.whisperPrompt == "")
    }
}
