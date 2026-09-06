import Foundation
@testable import LowTalkerCore
import Keystrokes
import Testing
import VirtualKeyboard
@testable import lowtalker

/// The report a stopped run makes, and which screen failures a poll may ride out. The
/// wire protocol these used to sit beside lives in the VirtualKeyboard module now, and the
/// character table lives in KeyboardLayout; both are tested where they live.

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

    /// A run that stopped between a dead key and the letter it accents left the target app
    /// holding a pending accent. It is not in the count - it is not on screen - and it is
    /// not nothing either: the next keystroke that app receives combines with it.
    @Test func aRunStoppedInsideACharacterSaysWhatIsPendingInTheApp() {
        let stopped = TypingStopped(typed: 12, of: 40, halfTyped: "\u{e9}", cause: DaemonError.silent)
        #expect("\(stopped)".contains("12 of 40 characters"))
        #expect("\(stopped)".contains("was left half typed"))
        #expect("\(stopped)".contains("\u{e9}"))
    }

    /// Every other stop is between characters, and saying nothing about a pending accent
    /// is the truth there. A report that hedged on every run would be read past.
    @Test func aRunStoppedBetweenCharactersSaysNothingAboutPendingAccents() {
        let stopped = TypingStopped(typed: 12, of: 40, cause: DaemonError.silent)
        #expect(!"\(stopped)".contains("half typed"))
    }
}

/// The two hand-transcribed key code tables in this repo, checked against each other.
///
/// `Usage(virtualKeyCode:)` was written from the ADB and HID tables for this epic;
/// `Modifier.hardware.keyCode` was written for the hotkey and the event poster, long
/// before it, and is exercised every time the hotkey works. Neither is derived from the
/// other, so where they overlap they are two witnesses rather than one repeated.
/// [LAW:one-source-of-truth] The character rows are checked against the spike's
/// driver-proven table in KeyboardLayoutTests; this is the modifier row, which types no
/// character and so appears in no layout map at all.
@Suite struct VirtualKeyCodeTests {
    @Test func theModifierRowAgreesWithTheTableTheHotkeyUses() {
        let expected: [Modifier: Usage] = [
            .leftShift: .leftShift, .rightShift: .rightShift,
            .leftControl: .leftControl, .rightControl: .rightControl,
            .leftOption: .leftOption, .rightOption: .rightOption,
            .leftCommand: .leftCommand, .rightCommand: .rightCommand,
        ]
        for (modifier, usage) in expected {
            #expect(Usage(virtualKeyCode: modifier.hardware.keyCode) == usage, "\(modifier) disagrees")
        }
        // Every side-specific modifier is covered; `function` has no HID keyboard usage,
        // and saying so here is what keeps this from silently covering seven of nine.
        #expect(Set(expected.keys).union([.function]) == Set(Modifier.allCases))
        #expect(Usage(virtualKeyCode: Modifier.function.hardware.keyCode) == nil)
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
