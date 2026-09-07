import KeyboardLayout
import Keystrokes
import LowTalkerCore
import Testing
import Typing

/// The typist against a keyboard the test plays, on the installed US layout.
@Suite @MainActor struct TypistTests {
    static let us = try! KeyboardLayout.named("com.apple.keylayout.US")
    static let rightOption = KeyChord(modifiers: .rightOption)

    @Test func textIsTypedCharacterByCharacterAndCounted() throws {
        let keyboard = RefusingKeyboard()
        let typist = Typist(keyboard: keyboard, hotkeys: [Self.rightOption])
        let text = try typist.lower("aB", on: Self.us)
        #expect(text.count == 2)
        #expect(try typist.type(text) == 2)
        #expect(keyboard.log == ["check", "down 4", "up", "check", "down e1", "check", "down 5", "up"])
    }

    @Test func nothingIsTypedForNothing() throws {
        let keyboard = RefusingKeyboard()
        let typist = Typist(keyboard: keyboard, hotkeys: [Self.rightOption])
        #expect(try typist.type(try typist.lower("", on: Self.us)) == 0)
        #expect(keyboard.log.isEmpty)
    }

    /// The layout's refusal comes back as it is, before any key: nothing was typed, so
    /// there is no count to carry.
    @Test func textTheLayoutCannotTypeIsRefusedWhole() {
        let keyboard = RefusingKeyboard()
        let typist = Typist(keyboard: keyboard, hotkeys: [Self.rightOption])
        #expect(throws: UntypeableCharacters.self) { try typist.lower("a\u{1F600}", on: Self.us) }
        #expect(keyboard.log.isEmpty)
    }

    /// Text lowers to the left modifiers, so the default hotkey is never in it. A hotkey
    /// on a left modifier is, and the text is refused before its first key rather than
    /// typed up to the character that would press it.
    @Test func textWhoseKeystrokeHoldsTheHotkeyIsRefusedBeforeAnyKey() throws {
        let keyboard = RefusingKeyboard()
        let typist = Typist(keyboard: keyboard, hotkeys: [KeyChord(modifiers: .leftShift)])
        #expect(throws: WouldPressTheHotkey.self) { try typist.lower("abC", on: Self.us) }
        #expect(keyboard.log.isEmpty)
        _ = try typist.lower("abc", on: Self.us)
        let right = Typist(keyboard: keyboard, hotkeys: [Self.rightOption])
        _ = try right.lower("abC \u{e9}\u{2014}", on: Self.us)
    }

    /// A chord names its sides, so it can hold the hotkey where text cannot. Right
    /// Option and E is Right Option going down first, which the tap hears as the hotkey.
    /// The modifiers go down in the order their bits run, and the tap begins a press only
    /// when exactly the hotkey is held: Right Command comes down after Right Option, so
    /// the hotkey is held alone on the way; Left Command comes down before it, so it never is.
    @Test func aChordHoldingTheHotkeyIsRefused() throws {
        let keyboard = RefusingKeyboard()
        let typist = Typist(keyboard: keyboard, hotkeys: [Self.rightOption])
        #expect(throws: WouldPressTheHotkey.self) { try typist.lower(KeyChord(key: Key(rawValue: 0x0E), modifiers: [.rightOption])) }
        #expect(throws: WouldPressTheHotkey.self) { try typist.lower(KeyChord(key: Key(rawValue: 0x0E), modifiers: [.rightOption, .rightCommand])) }
        _ = try typist.lower(KeyChord(key: Key(rawValue: 0x0E), modifiers: [.rightOption, .leftCommand]))
        _ = try typist.lower(KeyChord(key: Key(rawValue: 0x0E), modifiers: [.leftOption]))
        #expect(keyboard.log.isEmpty)
    }

    /// A hotkey with a key of its own is that key under exactly those modifiers and nothing
    /// else: the same modifiers over another key, or the key under more of them, is a
    /// different chord to the tap.
    @Test func aHotkeyWithAKeyRefusesOnlyThatKey() throws {
        let typist = Typist(keyboard: RefusingKeyboard(), hotkeys: [KeyChord(key: Key(rawValue: 0x31), modifiers: [.leftCommand, .leftShift])])
        #expect(throws: WouldPressTheHotkey.self) { try typist.lower(KeyChord(key: Key(rawValue: 0x31), modifiers: [.leftCommand, .leftShift])) }
        _ = try typist.lower(KeyChord(key: Key(rawValue: 0x00), modifiers: [.leftCommand, .leftShift]))
        _ = try typist.lower(KeyChord(key: Key(rawValue: 0x31), modifiers: [.leftCommand]))
        _ = try typist.lower(KeyChord(key: Key(rawValue: 0x31), modifiers: [.leftCommand, .leftShift, .leftOption]))
    }

    /// A hotkey holding Fn can never be pressed by this typist, so it refuses nothing -
    /// a keystroke holding the rest of it is not the hotkey to the tap.
    @Test func aHotkeyTheDeviceCannotHoldRefusesNothing() throws {
        let typist = Typist(keyboard: RefusingKeyboard(), hotkeys: [KeyChord(modifiers: .function, .rightOption)])
        _ = try typist.lower(KeyChord(key: Key(rawValue: 0x0E), modifiers: [.rightOption]))
    }

    @Test func aChordIsPressedAsOneKeystroke() throws {
        let keyboard = RefusingKeyboard()
        let typist = Typist(keyboard: keyboard, hotkeys: [Self.rightOption])
        try typist.press(try typist.lower(KeyChord(key: Key(rawValue: 0x24))))
        #expect(keyboard.log == ["check", "down 28", "up"])
    }

    /// A run that stops is reported with its count, and the keys are released on the way
    /// out: the modifiers of the keystroke it stopped inside would otherwise stay held.
    @Test func aStoppedRunReleasesTheKeysAndReportsTheCount() throws {
        let keyboard = StuckKeyboard()
        let typist = Typist(keyboard: keyboard, hotkeys: [Self.rightOption])
        let text = try typist.lower("abc", on: Self.us)
        let stopped = try #require(throws: TypingStopped.self) { try typist.type(text) }
        #expect(stopped.typed == 0)
        #expect(stopped.of == 3)
        #expect(stopped.cause is Refused)
        #expect(stopped.unreleased == nil)
        #expect(keyboard.log == ["check", "down 4", "up"])
        #expect(!"\(stopped)".contains("not released"))
    }

    /// A release that fails after the stop is said beside the stop, not instead of it:
    /// the operator is told the count and that a key may be held.
    @Test func aReleaseThatFailsAfterTheStopIsReported() throws {
        let keyboard = RefusingKeyboard()
        keyboard.allow = 4
        let typist = Typist(keyboard: keyboard, hotkeys: [Self.rightOption])
        let stopped = try #require(throws: TypingStopped.self) { try typist.type(try typist.lower("ab", on: Self.us)) }
        #expect(stopped.typed == 1)
        #expect(stopped.of == 2)
        #expect(stopped.unreleased is Refused)
        #expect("\(stopped)".hasSuffix("The keyboard was not released afterwards: Refused(). A key may be left held"))
    }

    @Test func aStoppedChordReleasesTheKeysToo() throws {
        let keyboard = StuckKeyboard()
        let typist = Typist(keyboard: keyboard, hotkeys: [Self.rightOption])
        let chord = try typist.lower(KeyChord(key: Key(rawValue: 0x00), modifiers: [.leftCommand]))
        let stopped = try #require(throws: ChordStopped.self) { try typist.press(chord) }
        #expect(stopped.cause is Refused)
        #expect(stopped.unreleased == nil)
        #expect(keyboard.log == ["check", "down e3", "up"])
    }
}

/// The report a stopped run makes. It has been wrong twice - once claiming nothing was
/// typed when a fragment was already in the document, once saying "the rest were not"
/// about a run where there was no rest - so what it says is checked rather than read.
@Suite struct TypingStoppedTests {
    @Test func aRunStoppedPartWaySaysHowMuchLandedAndThatTheRestDidNot() {
        let stopped = TypingStopped(typed: 34, of: 500, cause: ScreenUnreadable.wrongApp(wanted: "com.apple.TextEdit", frontmost: "com.googlecode.iterm2"))
        #expect("\(stopped)" == "com.googlecode.iterm2 is frontmost, not com.apple.TextEdit. 34 of 500 characters had been posted and acknowledged before this, and the rest were not sent")
    }

    /// The same failure after the last keystroke is a different fact, and claiming a
    /// remainder that does not exist is how the first version of this misled.
    @Test func aRunStoppedAfterTheLastKeystrokeClaimsNoRemainder() {
        let stopped = TypingStopped(typed: 40, of: 40, cause: Interrupted(number: 2))
        #expect("\(stopped)" == "interrupted by signal 2. all 40 characters had been posted and acknowledged before this")
    }

    /// A run that stopped between a dead key and the letter it accents left the target app
    /// holding a pending accent. It is not in the count - it is not on screen - and it is
    /// not nothing either: the next keystroke that app receives combines with it.
    @Test func aRunStoppedInsideACharacterSaysWhatIsPendingInTheApp() {
        let stopped = TypingStopped(typed: 12, of: 40, halfTyped: "\u{e9}", cause: Refused())
        #expect("\(stopped)".contains("12 of 40 characters"))
        #expect("\(stopped)".contains("was left half typed"))
        #expect("\(stopped)".contains("\u{e9}"))
    }

    /// Every other stop is between characters, and saying nothing about a pending accent
    /// is the truth there. A report that hedged on every run would be read past.
    @Test func aRunStoppedBetweenCharactersSaysNothingAboutPendingAccents() {
        let stopped = TypingStopped(typed: 12, of: 40, cause: Refused())
        #expect(!"\(stopped)".contains("half typed"))
    }
}

/// Which failures a poll may ride out. A wait exists because an app answers when it
/// answers, so a moment's silence from the target is the case polling is for - but an app
/// that is not in front will not come back on its own, and riding that out would deliver a
/// late verdict about the wrong window.
@Suite struct ScreenUnreadableTests {
    @Test func onlyTheFailuresTimeCanChangeAreRiddenOut() {
        #expect(ScreenUnreadable.noFocus("com.apple.TextEdit").mayPassWithTime)
        #expect(!ScreenUnreadable.noFrontmostApp.mayPassWithTime)
        #expect(!ScreenUnreadable.notRunning("com.apple.TextEdit").mayPassWithTime)
        #expect(!ScreenUnreadable.wouldNotComeForward(wanted: "a", frontmost: "b").mayPassWithTime)
        #expect(!ScreenUnreadable.wrongApp(wanted: "a", frontmost: "b").mayPassWithTime)
        // A process does not grow a bundle id while a poll waits, so riding this one out
        // would retry against something that can never answer.
        #expect(!ScreenUnreadable.frontmostWithoutBundleID(pid: 0).mayPassWithTime)
    }

    /// The untrusted case states the fact instead of offering "no such element" as the
    /// explanation - the hour that costs is what this message exists to save, so it is
    /// asserted rather than assumed.
    @Test func anUntrustedProcessSaysSoRatherThanBlamingTheElement() {
        let untrusted = ScreenUnreadable.noElement(role: "AXButton", title: "Cancel", app: "com.apple.SecurityAgent", trusted: false)
        let trusted = ScreenUnreadable.noElement(role: "AXButton", title: "Cancel", app: "com.apple.SecurityAgent", trusted: true)
        #expect("\(untrusted)" != "\(trusted)")
        #expect("\(untrusted)".contains("Accessibility"))
    }
}
