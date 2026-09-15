import Carbon.HIToolbox
import KeyboardLayout
import Keystrokes
import LowTalkerCore
import Testing
import Typing

/// A chord as a script spells it for `lowtalker keys`.
@Suite struct ChordSpellingTests {
    static let us = try! KeyboardLayout.named("com.apple.keylayout.US")
    static let dvorak = try! KeyboardLayout.named("com.apple.keylayout.Dvorak")

    @Test func modifiersAndACharacterNameTheKeyThatCharacterIsOn() throws {
        let chord = try KeyChord(spelled: "leftCommand+s", on: Self.us)
        #expect(chord == KeyChord(key: Key(rawValue: UInt16(kVK_ANSI_S)), modifiers: [.leftCommand]))
    }

    /// The character is the layout's: `s` on Dvorak is the key US calls semicolon.
    @Test func theCharacterIsReadOffTheLayout() throws {
        let chord = try KeyChord(spelled: "leftCommand+s", on: Self.dvorak)
        #expect(chord.key == Key(rawValue: UInt16(kVK_ANSI_Semicolon)))
    }

    @Test func aNamedKeyNeedsNoLayoutCharacter() throws {
        #expect(try KeyChord(spelled: "return", on: Self.us) == KeyChord(key: Key(rawValue: UInt16(kVK_Return))))
        #expect(try KeyChord(spelled: "leftShift+leftCommand+left", on: Self.us)
            == KeyChord(key: Key(rawValue: UInt16(kVK_LeftArrow)), modifiers: [.leftShift, .leftCommand]))
        #expect(try KeyChord(spelled: "f12", on: Self.us).key == Key(rawValue: UInt16(kVK_F12)))
    }

    /// Every name is a key the device can press, so no name parses into a refusal.
    @Test func everyNamedKeyIsPressable() {
        for (name, key) in KeyChord.namedKeys {
            #expect(Usage(virtualKeyCode: key.rawValue) != nil, "\(name) names key code \(key.rawValue), which has no usage")
        }
    }

    /// [LAW:one-source-of-truth] What the program prints for a chord is a spelling it reads.
    @Test func theSpellingHeldPrintsReadsBackAsTheSameChord() throws {
        let chords = [
            KeyChord(key: Key(rawValue: 0x24), modifiers: [.rightShift, .leftControl]),
            KeyChord(key: Key(rawValue: UInt16(kVK_ANSI_Keypad1))),
            Hotkey.defaultChord(for: .development, heardBy: .virtualKeyboard),
        ]
        for chord in chords {
            #expect(try KeyChord(spelled: Hotkey.held(chord), on: Self.us) == chord)
        }
    }

    /// Modifiers alone spell a chord; that the device cannot strike one is the keystroke's
    /// refusal, the same one a decoded chord gets.
    @Test func modifiersAloneParseAndAreRefusedWhereEveryChordIs() throws {
        let chord = try KeyChord(spelled: "rightOption", on: Self.us)
        #expect(chord == KeyChord(modifiers: .rightOption))
        #expect(throws: UnpressableChord.self) { try Keystroke(chord: chord) }
    }

    @Test func aCharacterThatNeedsAModifierIsNotAKey() {
        #expect(throws: ChordSpellingError.notOneKey("S", layout: "com.apple.keylayout.US")) { try KeyChord(spelled: "leftCommand+S", on: Self.us) }
        // A dead key and the letter under it is two keys.
        #expect(throws: ChordSpellingError.notOneKey("\u{e9}", layout: "com.apple.keylayout.US")) { try KeyChord(spelled: "\u{e9}", on: Self.us) }
    }

    @Test func whatNamesNoChordIsRefusedByName() {
        #expect(throws: ChordSpellingError.unknownTerm("cmd", in: "cmd+s")) { try KeyChord(spelled: "cmd+s", on: Self.us) }
        #expect(throws: ChordSpellingError.unknownTerm("", in: "leftCommand+")) { try KeyChord(spelled: "leftCommand+", on: Self.us) }
        #expect(throws: ChordSpellingError.unknownTerm("", in: "")) { try KeyChord(spelled: "", on: Self.us) }
        #expect(throws: ChordSpellingError.moreThanOneKey("a+b")) { try KeyChord(spelled: "a+b", on: Self.us) }
        #expect(throws: ChordSpellingError.notOneKey("\u{1F600}", layout: "com.apple.keylayout.US")) { try KeyChord(spelled: "\u{1F600}", on: Self.us) }
    }
}
