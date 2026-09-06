import Keystrokes
import Testing
@testable import lowtalker

/// A keyboard that records what it was asked to do and refuses after a given number of
/// calls, so a run can be stopped at any point inside a character.
///
/// One knob and not three: every call goes through the same counter, so "throw on the
/// second key-down of a two-keystroke character" and "throw on the release after it" are
/// the same test with a different number. [LAW:no-mode-explosion]
@MainActor
final class RefusingKeyboard: Keyboard {
    private(set) var log: [String] = []
    /// How many calls to let through before refusing every one after.
    var allow = Int.max

    private func record(_ what: String) throws {
        guard log.count < allow else { throw Refused() }
        log.append(what)
    }

    func check() throws { try record("check") }
    func down(_ usage: Usage) throws { try record("down \(String(usage.rawValue, radix: 16))") }
    func releaseAll() throws { try record("up") }
}

struct Refused: Error {}

/// What a run reports when it stops inside a character.
///
/// Two counts that move in opposite directions and must not be swapped: `typed` says
/// "posted and acknowledged", so a throw means it did not happen; `halfTyped` says "may be
/// pending in the app", so a throw means it might have. Every case below is a stop at a
/// different point in the same two-keystroke character.
@Suite @MainActor struct ScribeTests {
    /// Option-E then E: the shape of every accented character.
    static let acute = [Keystroke(Usage(rawValue: 0x08), .leftOption), Keystroke(Usage(rawValue: 0x08))]
    /// Shift-Option-hyphen: one keystroke, two modifiers, the em dash's shape.
    static let emDash = [Keystroke(Usage(rawValue: 0x2d), [.leftShift, .leftOption])]

    private func scribe(allowing calls: Int = .max) -> (Scribe, RefusingKeyboard) {
        let keyboard = RefusingKeyboard()
        keyboard.allow = calls
        return (Scribe(keyboard: keyboard), keyboard)
    }

    @Test func aCharacterIsCheckedPressedAndReleasedInThatOrder() throws {
        var (scribe, keyboard) = scribe()
        try scribe.press("a", [Keystroke(Usage(rawValue: 0x04))])
        #expect(keyboard.log == ["check", "down 4", "up"])
        #expect(scribe.typed == 1)
        #expect(scribe.halfTyped == nil)
    }

    /// Every modifier goes down before the key it modifies, in one press, and the release
    /// takes them all back up together.
    @Test func theModifiersOfAKeystrokeGoDownBeforeIt() throws {
        var (scribe, keyboard) = scribe()
        try scribe.press("\u{2014}", Self.emDash)
        #expect(keyboard.log == ["check", "down e1", "down e2", "down 2d", "up"])
        #expect(scribe.typed == 1)
    }

    /// The check runs before every keystroke and not once a character: an accented letter
    /// is two of them, and the window in which focus may move has to be one keystroke wide.
    @Test func everyKeystrokeIsCheckedAndNotEveryCharacter() throws {
        var (scribe, keyboard) = scribe()
        try scribe.press("\u{e9}", Self.acute)
        #expect(keyboard.log.filter { $0 == "check" }.count == 2)
        #expect(keyboard.log == ["check", "down e2", "down 8", "up", "check", "down 8", "up"])
    }

    /// Refused before anything was posted: nothing is on screen and nothing is pending, so
    /// both counts stay where they were.
    @Test func aRunRefusedBeforeItsFirstKeystrokeLeavesNothingBehind() {
        var (scribe, _) = scribe(allowing: 0)
        #expect(throws: Refused.self) { try scribe.press("\u{e9}", Self.acute) }
        #expect(scribe.typed == 0)
        #expect(scribe.halfTyped == nil)
    }

    /// The dead key was posted and the letter was not, at each of the four points where
    /// that can happen: the key-down that failed, the release after it, the check before
    /// the letter, and the letter's own key-down. The app is holding an accent in all four.
    @Test func aCharacterStoppedBeforeItsLastKeystrokeIsHalfTyped() {
        for stoppedAfter in [2, 3, 4, 5] {
            var (scribe, _) = scribe(allowing: stoppedAfter)
            #expect(throws: Refused.self) { try scribe.press("\u{e9}", Self.acute) }
            #expect(scribe.typed == 0, "stopped after \(stoppedAfter) calls")
            #expect(scribe.halfTyped == "\u{e9}", "stopped after \(stoppedAfter) calls")
        }
    }

    /// The last key-down was acknowledged, so the character is on screen even though the
    /// release that follows it failed. Counted, and no longer pending.
    @Test func aCharacterStoppedAfterItsLastKeystrokeIsTypedAndNotPending() {
        var (scribe, _) = scribe(allowing: 6)
        #expect(throws: Refused.self) { try scribe.press("\u{e9}", Self.acute) }
        #expect(scribe.typed == 1)
        #expect(scribe.halfTyped == nil)
    }

    /// A modifier that would not go down leaves nothing pending: no key of the character
    /// was posted, so there is no accent in the app to combine with the next one. True of
    /// the em dash's second modifier and of the dead key's own - `halfTyped` is recorded
    /// between the modifiers and the key, which is where the pending accent begins.
    @Test func aKeystrokeStoppedAmongItsModifiersLeavesNothingPending() {
        var (dash, _) = scribe(allowing: 2)
        #expect(throws: Refused.self) { try dash.press("\u{2014}", Self.emDash) }
        #expect(dash.typed == 0)
        #expect(dash.halfTyped == nil)

        var (accent, _) = scribe(allowing: 1)
        #expect(throws: Refused.self) { try accent.press("\u{e9}", Self.acute) }
        #expect(accent.typed == 0)
        #expect(accent.halfTyped == nil)
    }

    /// The count carries across characters, and a stop mid-way reports the ones already
    /// posted rather than starting over.
    @Test func theCountIsOfTheRunAndNotOfOneCharacter() throws {
        var (scribe, keyboard) = scribe()
        for character in "abc" { try scribe.press(character, [Keystroke(Usage(rawValue: 0x04))]) }
        #expect(scribe.typed == 3)
        keyboard.allow = keyboard.log.count + 2
        #expect(throws: Refused.self) { try scribe.press("\u{e9}", Self.acute) }
        #expect(scribe.typed == 3)
        #expect(scribe.halfTyped == "\u{e9}")
    }
}
