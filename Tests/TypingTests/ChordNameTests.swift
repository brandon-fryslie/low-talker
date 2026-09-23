import Carbon.HIToolbox
import KeyboardLayout
import LowTalkerCore
import Testing
import Typing

/// A chord in the words a person presses it by, for each way it is heard.
@Suite @MainActor struct ChordNameTests {
    static let us = try! KeyboardLayout.named("com.apple.keylayout.US")
    static let dvorak = try! KeyboardLayout.named("com.apple.keylayout.Dvorak")

    /// A registered hot key names no sides, since Carbon hears either, and names its key as
    /// the layout prints it.
    @Test func aRegisteredChordNamesNoSidesAndTheLayoutsKey() {
        let chord = KeyChord(key: Key(rawValue: UInt16(kVK_ANSI_D)), modifiers: [.leftCommand, .rightOption, .leftControl])
        #expect(Hotkey.named(chord, heardBy: .registeredHotKey, on: Self.us) == "Control+Option+Command+D")
        // The same physical key is E on Dvorak, which is what that user sees on it.
        #expect(Hotkey.named(chord, heardBy: .registeredHotKey, on: Self.dvorak) == "Control+Option+Command+E")
    }

    /// A key that types nothing alone keeps the code, which still says which key it is.
    @Test func aKeyWithNoCharacterIsNamedByItsCode() {
        let chord = KeyChord(key: Key(rawValue: UInt16(kVK_F5)), modifiers: [.leftControl])
        #expect(Hotkey.named(chord, heardBy: .registeredHotKey, on: Self.us) == "Control+key 0x60")
    }

    /// The event tap hears sides and order, so its chord is spelled the way `held` spells it.
    @Test func aTappedChordIsSpelledWithItsSides() {
        let chord = Hotkey.defaultChord(for: .development, heardBy: .eventTap)
        #expect(Hotkey.named(chord, heardBy: .eventTap, on: Self.us) == Hotkey.held(chord))
    }
}
