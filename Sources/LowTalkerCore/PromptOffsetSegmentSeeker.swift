import CoreML
import WhisperKit

/// WhisperKit's segment seeker, reading its alignment rows from where the
/// transcript's tokens begin once a prompt stands before them.
///
/// WhisperKit 1.1.0 writes the alignment row of every decoder step at the step's
/// index in the whole prefilled sequence, and a prompt goes at the front of that
/// sequence as `<|startofprev|>` and the prompt's tokens (TextDecoder.
/// prepareDecoderInputs). The tokens it aligns are cut from `<|startoftranscript|>`
/// (decodeText) and their rows are read by their index in that cut
/// (SegmentSeeker.addWordTimestamps), so with a prompt of P tokens every word is
/// read P+1 rows early and short windows lose every word. This seeker hands
/// WhisperKit's own seeker the rows from `<|startoftranscript|>` on, and is
/// otherwise that seeker.
///
/// [LAW:one-source-of-truth] The prompt's rows are counted by the rule the text
/// decoder prefills with: the prompt's last `promptTokenLimit` tokens with special
/// tokens dropped, and `<|startofprev|>` before them when any are left. Exception:
/// the rule is restated here because WhisperKit does not expose it, and it is
/// restated once, so the transcriber's refusal of a long prompt derives from here.
struct PromptOffsetSegmentSeeker: SegmentSeeking {
    private let seeker = SegmentSeeker()

    /// The most prompt tokens WhisperKit prefills; a longer prompt keeps its last
    /// this many.
    static let promptTokenLimit = Constants.maxTokenContext / 2 - 1

    /// How many rows the prompt took before the transcript's first row: none for
    /// no prompt, else `<|startofprev|>` and the tokens WhisperKit kept of it.
    static func promptRows(before promptTokens: [Int]?, specialTokenBegin: Int) -> Int {
        let kept = (promptTokens ?? []).suffix(promptTokenLimit).filter { $0 < specialTokenBegin }
        return kept.isEmpty ? 0 : kept.count + 1
    }

    func findSeekPointAndSegments(
        decodingResult: DecodingResult,
        options: DecodingOptions,
        allSegmentsCount: Int,
        currentSeek seek: Int,
        segmentSize: Int,
        sampleRate: Int,
        timeToken: Int,
        specialToken: Int,
        tokenizer: WhisperTokenizer
    ) -> (Int, [TranscriptionSegment]?) {
        seeker.findSeekPointAndSegments(
            decodingResult: decodingResult,
            options: options,
            allSegmentsCount: allSegmentsCount,
            currentSeek: seek,
            segmentSize: segmentSize,
            sampleRate: sampleRate,
            timeToken: timeToken,
            specialToken: specialToken,
            tokenizer: tokenizer
        )
    }

    func addWordTimestamps(
        segments: [TranscriptionSegment],
        alignmentWeights: MLMultiArray,
        tokenizer: WhisperTokenizer,
        seek: Int,
        segmentSize: Int,
        prependPunctuations: String,
        appendPunctuations: String,
        lastSpeechTimestamp: Float,
        options: DecodingOptions,
        timings: TranscriptionTimings
    ) throws -> [TranscriptionSegment]? {
        let promptRows = Self.promptRows(before: options.promptTokens, specialTokenBegin: tokenizer.specialTokens.specialTokenBegin)
        return try alignmentWeights.withRows(from: promptRows) { transcriptRows in
            try seeker.addWordTimestamps(
                segments: segments,
                alignmentWeights: transcriptRows,
                tokenizer: tokenizer,
                seek: seek,
                segmentSize: segmentSize,
                prependPunctuations: prependPunctuations,
                appendPunctuations: appendPunctuations,
                lastSpeechTimestamp: lastSpeechTimestamp,
                options: options,
                timings: timings
            )
        }
    }
}

extension MLMultiArray {
    /// Calls `body` with the rows from `first` on: a view over this array's own
    /// storage, not a copy, that lives for the call. The leading dimension is the
    /// rows; the others are kept whole.
    func withRows<Result>(from first: Int, _ body: (MLMultiArray) throws -> Result) throws -> Result {
        try withUnsafeMutableBytes { bytes, strides in
            // A view onto storage that outlives it needs no deallocator, and a
            // tensor with rows has an address.
            let view = try MLMultiArray(
                dataPointer: bytes.baseAddress! + first * strides[0] * dataType.bytesPerElement,
                shape: [shape[0].intValue - first as NSNumber] + shape.dropFirst(),
                dataType: dataType,
                strides: strides.map { $0 as NSNumber },
                deallocator: nil
            )
            return try body(view)
        }
    }
}

extension MLMultiArrayDataType {
    /// The unit the strides count in.
    var bytesPerElement: Int {
        switch self {
        case .float16: 2
        case .float32: 4
        case .double: 8
        case .int32: 4
        @unknown default: fatalError("MLMultiArrayDataType \(rawValue) has no known element size")
        }
    }
}
