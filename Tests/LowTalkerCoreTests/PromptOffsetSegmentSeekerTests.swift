import CoreML
@testable import LowTalkerCore
import Testing
import WhisperKit

/// The row shift that keeps word timings under a prompt, exercised on hand-built
/// tensors; the seeker over a real decode is exercised by `lowtalker bench` with
/// `--vocabulary`, which is where the timings were lost.
@Suite struct PromptOffsetSegmentSeekerTests {
    static let specialTokenBegin = 50257

    /// No prompt takes no rows; a prompt takes one for `<|startofprev|>` and one
    /// per token WhisperKit keeps, which is none of the special ones.
    @Test func thePromptRowsAreStartOfPrevAndTheKeptTokens() {
        #expect(PromptOffsetSegmentSeeker.promptRows(before: nil, specialTokenBegin: Self.specialTokenBegin) == 0)
        #expect(PromptOffsetSegmentSeeker.promptRows(before: [], specialTokenBegin: Self.specialTokenBegin) == 0)
        #expect(PromptOffsetSegmentSeeker.promptRows(before: [12812, 77, 45533], specialTokenBegin: Self.specialTokenBegin) == 4)
        #expect(PromptOffsetSegmentSeeker.promptRows(before: [50362, 12812, 77], specialTokenBegin: Self.specialTokenBegin) == 3)
        #expect(PromptOffsetSegmentSeeker.promptRows(before: [50362], specialTokenBegin: Self.specialTokenBegin) == 0)
    }

    /// A prompt past the limit keeps its last `promptTokenLimit` tokens, as
    /// WhisperKit's decoder prefills it.
    @Test func aLongPromptIsCountedByWhatWhisperKitKeeps() {
        let limit = PromptOffsetSegmentSeeker.promptTokenLimit
        let long = Array(0..<(limit + 40))
        #expect(PromptOffsetSegmentSeeker.promptRows(before: long, specialTokenBegin: Self.specialTokenBegin) == limit + 1)
    }

    /// The view from row `first` is the same storage seen from that row: shape
    /// short by `first` rows, every element the one `first` rows down, and a write
    /// through the view lands in the array.
    @Test(arguments: [0, 1, 3])
    func theRowsFromFirstAreAViewOverTheSameStorage(first: Int) throws {
        let array = try MLMultiArray(shape: [4, 3], dataType: .float16)
        for row in 0..<4 {
            for column in 0..<3 {
                array[[row, column] as [NSNumber]] = NSNumber(value: Float(row * 10 + column))
            }
        }
        try array.withRows(from: first) { view in
            #expect(view.shape.map(\.intValue) == [4 - first, 3])
            for row in 0..<(4 - first) {
                for column in 0..<3 {
                    #expect(view[[row, column] as [NSNumber]].floatValue == Float((row + first) * 10 + column))
                }
            }
            view[[0, 0] as [NSNumber]] = NSNumber(value: Float(99))
        }
        #expect(array[[first, 0] as [NSNumber]].floatValue == 99)
    }
}
