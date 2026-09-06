import Keystrokes
import Testing

/// The modifier byte, read both ways. `Modifiers` and a set of modifier usages are one
/// value seen from two sides, and what makes the pair worth having is that neither side
/// can lose anything crossing to the other - which is a property, not an example, so it is
/// checked over every value there is rather than over the ones that came to mind.
@Suite struct ModifiersTests {
    /// All 256 of them. A bit that mapped to the wrong usage, or a usage whose bit was
    /// computed from the wrong end, would survive any example anyone thought to write.
    @Test func everyModifierByteSurvivesTheTripThroughItsUsagesAndBack() {
        for raw in UInt8.min...UInt8.max {
            let modifiers = Modifiers(rawValue: raw)
            #expect(Modifiers(modifiers.usages) == modifiers, "\(raw) did not come back")
            #expect(modifiers.usages.count == raw.nonzeroBitCount)
        }
    }

    /// The bits run in the order the usages do, which is the whole reason neither is
    /// tabulated beside the other. [LAW:one-source-of-truth]
    @Test func eachBitIsTheUsageItStandsFor() {
        let inOrder: [(Modifiers, Usage)] = [
            (.leftControl, .leftControl), (.leftShift, .leftShift),
            (.leftOption, .leftOption), (.leftCommand, .leftCommand),
            (.rightControl, .rightControl), (.rightShift, .rightShift),
            (.rightOption, .rightOption), (.rightCommand, .rightCommand),
        ]
        for (index, pair) in inOrder.enumerated() {
            #expect(pair.0.rawValue == 1 << index)
            #expect(pair.0.usages == [pair.1])
            #expect(Modifiers([pair.1]) == pair.0)
        }
    }

    /// A key that is not a modifier sets no bit, because there is no bit for it to set.
    /// Both sides are held so nothing quietly drops: the shift survives the company.
    @Test func aKeyThatIsNotAModifierContributesNothing() {
        #expect(Modifiers([Usage(rawValue: 0x04)]).isEmpty)
        #expect(Modifiers([Usage(rawValue: 0x04), .leftShift]) == .leftShift)
        #expect(Modifiers([] as [Usage]).isEmpty)
    }
}
