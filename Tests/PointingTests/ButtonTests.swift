import Testing
@testable import Pointing

/// The vocabulary stands on its own, so its tests do too. [LAW:decomposition]
@Suite struct ButtonTests {
    /// The report has 32 bits, so there are 32 buttons and no other.
    @Test func onlyTheThirtyTwoButtonsWithABitExist() {
        #expect(Button(rawValue: 0) == nil)
        #expect(Button(rawValue: 1)?.rawValue == 1)
        #expect(Button(rawValue: 32)?.rawValue == 32)
        #expect(Button(rawValue: 33) == nil)
    }

    /// Button n is bit n - 1, so left is the low bit and 32 is the high one.
    @Test func aButtonsBitComesFromItsNumber() {
        #expect(Button.left.bit == 0x1)
        #expect(Button.right.bit == 0x2)
        #expect(Button.middle.bit == 0x4)
        #expect(Button(rawValue: 32)!.bit == 0x8000_0000)
    }
}

@Suite struct CountTests {
    /// The descriptor says -127 through 127; clamping folds everything outside to the edge.
    @Test func clampingFoldsToTheDescriptorsRange() {
        #expect(Count(clamping: 0).value == 0)
        #expect(Count(clamping: 127).value == 127)
        #expect(Count(clamping: 128).value == 127)
        #expect(Count(clamping: 4000).value == 127)
        #expect(Count(clamping: -127).value == -127)
        #expect(Count(clamping: -128).value == -127)
        #expect(Count(clamping: Int.min).value == -127)
    }

    /// -128 is an `Int8` and not a count: the one value the wire can carry that the
    /// descriptor cannot, refused rather than folded. [LAW:no-silent-failure]
    @Test func exactlyRefusesTheOneInt8OutsideTheRange() {
        #expect(Count(exactly: -128) == nil)
        #expect(Count(exactly: -127)?.value == -127)
        #expect(Count(exactly: 127)?.value == 127)
    }
}
