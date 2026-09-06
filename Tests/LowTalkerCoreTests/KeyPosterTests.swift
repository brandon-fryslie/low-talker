import CoreGraphics
import LowTalkerCore
import Testing

@Suite struct KeystrokeTests {
    private let shiftBits = CGEventFlags(rawValue: 0x2 | 0x4)

    /// Both shifts held: the side-blind Shift bit stays set until the last one is up.
    @Test func aSideBlindBitOutlivesTheFirstOfTwoSidesReleased() {
        let strokes = KeyChord(key: Key(rawValue: 0), modifiers: [.leftShift, .rightShift]).keystrokes
        #expect(strokes.map(\.type) == [.flagsChanged, .flagsChanged, .keyDown, .keyUp, .flagsChanged, .flagsChanged])
        #expect(strokes.map(\.key) == [56, 60, 0, 0, 60, 56])
        #expect(strokes.map(\.flags) == [
            .maskShift.union(CGEventFlags(rawValue: 0x2)),
            .maskShift.union(shiftBits),
            .maskShift.union(shiftBits),
            .maskShift.union(shiftBits),
            .maskShift.union(CGEventFlags(rawValue: 0x2)),
            [],
        ])
    }

    @Test func aModifierOnlyChordHasNoKeyEvents() {
        let strokes = KeyChord(modifiers: .rightOption).keystrokes
        #expect(strokes.map(\.type) == [.flagsChanged, .flagsChanged])
        #expect(strokes.map(\.flags) == [.maskAlternate.union(CGEventFlags(rawValue: 0x40)), []])
    }
}
