import Foundation
import Testing
import VirtualKeyboard
@testable import lowtalker

/// The character table the spike types from, and the report a stopped run makes. The wire
/// protocol these used to sit beside now lives in the VirtualKeyboard module and is tested
/// there, against a fake daemon on a real socket.

@Suite struct USLayoutTests {
    /// The letters run from usage 0x04 in alphabetical order. Written out rather than
    /// derived, because deriving it from the same expression the table uses would prove
    /// only that the expression equals itself.
    @Test func theLettersRunFromUsageFourInOrder() throws {
        let typed = try USLayout.keystrokes(for: "abcdefghijklmnopqrstuvwxyz")
        #expect(typed.map(\.usage) == Array(0x04...0x1d))
        #expect(typed.allSatisfy { !$0.shift })
    }

    /// The digits run from 0x1e and start at one, not zero: 0x27 types "0", which is the
    /// off-by-one this table invites.
    @Test func theDigitsRunFromUsageThirtyWithZeroLast() throws {
        let typed = try USLayout.keystrokes(for: "1234567890")
        #expect(typed.map(\.usage) == Array(0x1e...0x27))
    }

    /// A shifted character types the same key as its unshifted twin, with shift. This is
    /// the check that catches a transposition inside either run, since a slip moves a
    /// character to a usage its twin does not share.
    @Test func everyShiftedCharacterSharesItsTwinsUsage() throws {
        for (plain, shifted) in zip("abcdefghijklmnopqrstuvwxyz1234567890", "ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()") {
            let bare = try USLayout.keystrokes(for: String(plain))[0]
            let held = try USLayout.keystrokes(for: String(shifted))[0]
            #expect(bare.usage == held.usage, "\(plain) and \(shifted) should be one key")
            #expect(!bare.shift)
            #expect(held.shift)
        }
    }

    /// The punctuation pairs, both halves, since these are transcribed from the usage
    /// tables by hand and nothing else in the file checks them.
    @Test func thePunctuationPairsShareTheirKeys() throws {
        for (plain, shifted) in zip("-=[]\\;'`,./", "_+{}|:\"~<>?") {
            let bare = try USLayout.keystrokes(for: String(plain))[0]
            let held = try USLayout.keystrokes(for: String(shifted))[0]
            #expect(bare.usage == held.usage, "\(plain) and \(shifted) should be one key")
            #expect(held.shift)
        }
    }

    /// Two characters that type the same key with the same modifier would mean one of
    /// them never arrives as itself. Nothing in the table's construction prevents it.
    @Test func noTwoCharactersClaimTheSameKeyAndModifier() throws {
        let alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890!@#$%^&*()-=[]\\;'`,./_+{}|:\"~<>? \n\t"
        let typed = try USLayout.keystrokes(for: alphabet)
        #expect(Set(typed.map { "\($0.usage)-\($0.shift)" }).count == alphabet.count)
    }

    /// Whitespace types keys, not nothing: newline is Return, tab is Tab, space is Space.
    @Test func theThreeWhitespaceCharactersTypeTheirOwnKeys() throws {
        #expect(try USLayout.keystrokes(for: "\n")[0].usage == 0x28)
        #expect(try USLayout.keystrokes(for: "\t")[0].usage == 0x2b)
        #expect(try USLayout.keystrokes(for: " ")[0].usage == 0x2c)
    }

    /// [LAW:parse-dont-validate] A character the layout cannot type is refused here and
    /// named, so nothing downstream has to decide what to do with it - and a partly
    /// typeable string is refused whole rather than typed up to the bad character.
    @Test func aCharacterTheLayoutCannotTypeIsRefusedByName() {
        #expect(throws: UntypeableCharacters.self) { try USLayout.keystrokes(for: "café") }
        #expect(throws: UntypeableCharacters.self) { try USLayout.keystrokes(for: "hello 😀") }
        do {
            _ = try USLayout.keystrokes(for: "a€b£c")
            Issue.record("the layout claimed it could type € and £")
        } catch let refusal as UntypeableCharacters {
            #expect(refusal.characters == "€£")
        } catch {
            Issue.record("refused with \(error) rather than naming the characters")
        }
    }

    @Test func typingNothingIsRefused() {
        #expect(throws: (any Error).self) { try USLayout.keystrokes(for: "") }
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
        let stopped = TypingStopped(typed: 40, of: 40, cause: Interrupted(number: SIGINT))
        #expect("\(stopped)" == "interrupted by signal 2. all 40 characters had been posted and acknowledged before this")
    }

    /// Any cause, not only a screen one: a daemon that goes quiet mid-burst leaves just
    /// as much text behind, and the operator needs the same number.
    @Test func aDaemonFailureCarriesTheCountToo() {
        let stopped = TypingStopped(typed: 7, of: 40, cause: DaemonError.silent)
        #expect("\(stopped)".hasPrefix("the daemon did not answer in time. 7 of 40"))
    }
}

/// Which failures a poll may ride out. A wait exists because an app answers when it
/// answers, so a moment's silence from the target is the case polling is for - but an app
/// that is not in front will not come back on its own, and riding that out would deliver a
/// late verdict about the wrong window.
@Suite struct ScreenUnreadableTests {
    @Test func onlyTheFailuresTimeCanChangeAreRiddenOut() {
        #expect(ScreenUnreadable.noFocus("com.apple.TextEdit").mayPassWithTime)
        #expect(ScreenUnreadable.noText("com.apple.TextEdit").mayPassWithTime)
        #expect(!ScreenUnreadable.noFrontmostApp.mayPassWithTime)
        #expect(!ScreenUnreadable.notRunning("com.apple.TextEdit").mayPassWithTime)
        #expect(!ScreenUnreadable.wouldNotComeForward(wanted: "a", frontmost: "b").mayPassWithTime)
        #expect(!ScreenUnreadable.wrongApp(wanted: "a", frontmost: "b").mayPassWithTime)
    }
}
