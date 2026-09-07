import Keystrokes
import LowTalkerCore
import Testing
import Typing

/// A chord lowered to the keystroke the device presses. These replace the tests of the
/// CGEvent poster, which lowered a chord to window server events: the act is the same
/// and the vocabulary is the device's now.
@Suite struct ChordLoweringTests {
    /// Cmd-Shift-A, the shape of every keyboard shortcut: the key under the modifiers,
    /// each side kept as the chord named it.
    @Test func aShortcutIsTheKeyUnderItsModifiers() throws {
        let keystroke = try Keystroke(chord: KeyChord(key: Key(rawValue: 0x00), modifiers: [.leftCommand, .rightShift]))
        #expect(keystroke == Keystroke(Usage(rawValue: 0x04), [.leftCommand, .rightShift]))
    }

    @Test func aBareKeyHoldsNothing() throws {
        #expect(try Keystroke(chord: KeyChord(key: Key(rawValue: 0x24))) == Keystroke(.returnKey))
    }

    /// Modifiers alone are a hotkey, held and released, and a keystroke cannot say that.
    @Test func aModifierOnlyChordCannotBePressed() {
        #expect(throws: UnpressableChord.self) { try Keystroke(chord: KeyChord(modifiers: .rightOption)) }
    }

    /// Fn is not a key to the device: the keyboard page has no usage for it.
    @Test func aChordHoldingFnCannotBePressed() {
        #expect(throws: UnpressableChord.self) { try Keystroke(chord: KeyChord(key: Key(rawValue: 0x00), modifiers: [.function])) }
    }

    @Test func aKeyCodeTheKeyboardPageDoesNotNameCannotBePressed() {
        #expect(throws: UnpressableChord.self) { try Keystroke(chord: KeyChord(key: Key(rawValue: 0xFFFF))) }
    }

    @Test func theRefusalNamesTheChord() {
        let refusal = UnpressableChord(chord: KeyChord(key: Key(rawValue: 0x00), modifiers: [.function, .leftCommand]), because: "why")
        #expect("\(refusal)" == "the chord leftCommand+function+key 0x0 cannot be pressed: why")
    }
}

/// The two hand-transcribed key code tables in this repo, checked against each other.
///
/// `Usage(virtualKeyCode:)` was written from the ADB and HID tables for the keyboard
/// epic; `Modifier.hardware.keyCode` was written for the hotkey and the event poster,
/// long before it, and is exercised every time the hotkey works. Neither is derived from
/// the other, so where they overlap they are two witnesses rather than one repeated -
/// and `Modifier.usage` is that overlap, used. [LAW:one-source-of-truth] The character
/// rows are checked against the spike's driver-proven table in KeyboardLayoutTests; this
/// is the modifier row, which types no character and so appears in no layout map at all.
@Suite struct ModifierUsageTests {
    @Test func theModifierRowAgreesWithTheTableTheHotkeyUses() {
        let expected: [Modifier: Usage] = [
            .leftShift: .leftShift, .rightShift: .rightShift,
            .leftControl: .leftControl, .rightControl: .rightControl,
            .leftOption: .leftOption, .rightOption: .rightOption,
            .leftCommand: .leftCommand, .rightCommand: .rightCommand,
        ]
        for (modifier, usage) in expected {
            #expect(modifier.usage == usage, "\(modifier) disagrees")
        }
        // Every side-specific modifier is covered; `function` has no HID keyboard usage,
        // and saying so here is what keeps this from silently covering seven of nine.
        #expect(Set(expected.keys).union([.function]) == Set(Modifier.allCases))
        #expect(Modifier.function.usage == nil)
    }
}
