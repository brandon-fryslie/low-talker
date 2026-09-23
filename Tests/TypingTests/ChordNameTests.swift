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

    /// The event tap hears sides, so its chord names them, in words and in the order that
    /// works: Right Command first, since Right Option alone is the release copy's chord.
    @Test func aTappedChordIsSpelledWithItsSidesInPressOrder() {
        let chord = Hotkey.defaultChord(for: .development, heardBy: .eventTap)
        #expect(Hotkey.named(chord, heardBy: .eventTap, on: Self.us) == "Right Command+Right Option")
        let keyed = KeyChord(key: Key(rawValue: UInt16(kVK_ANSI_D)), modifiers: [.leftShift])
        #expect(Hotkey.named(keyed, heardBy: .eventTap, on: Self.dvorak) == "Left Shift+E")
    }

    /// A chord of modifiers alone has no letter to name, so it is named without asking the
    /// layout, and a layout that cannot be read does not stop it: `dictate` names such a
    /// chord after its tap is up, where a failure would end the command. A chord with a key
    /// does ask, and says why it could not be named.
    @Test func onlyAChordWithAKeyReadsTheLayout() throws {
        struct Unreadable: Error {}
        func unreadable() throws -> KeyboardLayout { throw Unreadable() }
        let modifiersAlone = Hotkey.defaultChord(for: .development, heardBy: .eventTap)
        #expect(try Hotkey.named(modifiersAlone, heardBy: .eventTap, on: unreadable()) == "Right Command+Right Option")
        let keyed = Hotkey.defaultChord(for: .development, heardBy: .registeredHotKey)
        #expect(throws: Unreadable.self) { try Hotkey.named(keyed, heardBy: .registeredHotKey, on: unreadable()) }
    }
}
