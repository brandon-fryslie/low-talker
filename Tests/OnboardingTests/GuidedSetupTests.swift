import Choices
import Flavors
import Foundation
import Grants
import Testing
@testable import Onboarding

/// The guided setup as a person meets it: one requirement at a time, each explained before
/// macOS is asked, and a walk that survives a "no". [LAW:behavior-not-structure]
@Suite struct GuidedSetupTests {
    static let flavor = Flavor.development

    // MARK: - the words before the dialog

    /// Every step says what it is for and what happens if you skip it, before anything is
    /// asked of macOS. A step missing either is the unexplained prompt this setup exists to
    /// replace.
    @Test(arguments: Requirement.Row.allCases, Flavor.allCases)
    func everyStepExplainsWhyAndWhatSkippingCosts(row: Requirement.Row, flavor: Flavor) {
        let explanation = row.explanation(for: flavor)
        for (part, text) in [("why", explanation.why), ("if skipped", explanation.ifSkipped)] {
            #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(row.rawValue) has no \(part)")
        }
    }

    /// A step that names the app names the installation it is shown in, in every part of
    /// its explanation. "LowTalker Dev" contains "LowTalker", so containment alone would
    /// pass a part hardcoding the release name; a part that names the app is required to
    /// differ between the two instead.
    @Test func aStepNamingTheAppNamesTheInstallationItIsShownIn() {
        let parts: [(name: String, of: (Explanation) -> String)] = [("why", \.why), ("if skipped", \.ifSkipped)]
        for row in Requirement.Row.allCases {
            for part in parts {
                let texts = Flavor.allCases.map { part.of(row.explanation(for: $0)) }
                if texts.contains(where: { $0.contains(Flavor.release.displayName) }) {
                    #expect(Set(texts).count == Flavor.allCases.count, "\(row.rawValue)'s \(part.name) reads the same for every installation")
                }
            }
        }
    }

    /// A step the app can ask macOS about has a button saying what it asks; the two it
    /// cannot ask about - the driver, which an administrator installs, and the assistant,
    /// which the helper answers - have none, so no button promises a dialog that never comes.
    @Test func onlyTheRowsTheAppCanAskForHaveAnAskButton() {
        let asking = Requirement.Row.allCases.filter { $0.askTitle != nil }
        #expect(asking == [.microphone, .accessibility, .inputMonitoring, .inputMethod, .keyboardHelper])
        for row in asking { #expect(row.askTitle?.hasSuffix("…") == true, "\(row.rawValue)'s button does not say a dialog follows") }
    }

    /// Every grant a person can switch by hand has the pane it is switched in, which is
    /// where a person goes after declining a dialog macOS will not show twice.
    @Test func everyGrantOpensTheExactPaneItIsSwitchedIn() {
        #expect(Requirement.Row.microphone.settingsPane?.absoluteString.hasSuffix("Privacy_Microphone") == true)
        #expect(Requirement.Row.inputMonitoring.settingsPane?.absoluteString.hasSuffix("Privacy_ListenEvent") == true)
        #expect(Requirement.Row.accessibility.settingsPane?.absoluteString.hasSuffix("Privacy_Accessibility") == true)
        #expect(Requirement.Row.inputMethod.settingsPane?.absoluteString.hasSuffix("com.apple.Keyboard-Settings.extension") == true)
        #expect(Requirement.Row.driverExtension.settingsPane?.absoluteString.hasSuffix("com.apple.LoginItems-Settings.extension") == true)
        #expect(Requirement.Row.keyboardHelper.settingsPane?.absoluteString.hasSuffix("com.apple.LoginItems-Settings.extension") == true)
        #expect(Requirement.Row.keyboardSetupAssistant.settingsPane == nil)
    }

    // MARK: - the input method's dialog, which returns

    /// Only the input method is re-askable. macOS shows the others' dialogs once per app, so
    /// their button is spent after one press and the page sends the person to System
    /// Settings; the input method's dialog comes back on the next press (measured on
    /// studious 2026-09-27), so its button must stay and it must never get the "asks only
    /// once" line. A row landing on the wrong side of this is the exact defect ssn fixes.
    @Test func onlyTheInputMethodIsReAskable() {
        for row in Requirement.Row.allCases {
            #expect(row.reAskable == (row == .inputMethod), "\(row.rawValue)")
        }
    }

    /// Only the input method carries a switch-on note. The others' asking is fully covered
    /// by the generic once-asked line, so a note on them would be a second, competing voice.
    @Test func onlyTheInputMethodCarriesASwitchOnNote() {
        for row in Requirement.Row.allCases {
            #expect((row.switchOnNote(for: Self.flavor) != nil) == (row == .inputMethod), "\(row.rawValue)")
        }
    }

    /// The note names both facts a person cannot see coming and would otherwise be left to
    /// discover: that declining is not the end because the dialog returns, and that nothing
    /// happening means the source waits for the next login. [LAW:no-silent-failure] Naming
    /// neither is the silent failure; naming the login as unconditional would be the false
    /// claim the previous wording made.
    @Test func theInputMethodNoteNamesTheReturningDialogAndTheLogin() throws {
        let note = try #require(Requirement.Row.inputMethod.switchOnNote(for: Self.flavor))
        #expect(note.contains("Allow"), "the note never names the dialog to allow it")
        #expect(note.contains("again"), "the note never says the dialog returns after a No")
        #expect(note.contains("log out") && note.contains("back in"), "the note never names the login")
    }

    /// The note names the installation it is shown in, so the development copy does not tell
    /// a person to reopen the release. "LowTalker Dev" contains "LowTalker", so the two
    /// notes are required to differ rather than merely to contain a name.
    @Test func theInputMethodNoteNamesTheInstallation() {
        let notes = Flavor.allCases.compactMap { Requirement.Row.inputMethod.switchOnNote(for: $0) }
        #expect(notes.count == Flavor.allCases.count)
        #expect(Set(notes).count == Flavor.allCases.count, "the note reads the same for every installation")
    }

    /// A note that tells the person to press the button again is claiming the same fact
    /// `reAskable` carries, so the two may not drift: were `reAskable` ever flipped off
    /// while the note kept saying "again", the page would hide the button the note still
    /// tells them to press. Ties the prose to the boolean, which nothing else does.
    @Test func aNotePromisingAnotherPressIsOnlyOnAReAskableRow() {
        for row in Requirement.Row.allCases where row.switchOnNote(for: Self.flavor)?.contains("again") == true {
            #expect(row.reAskable, "\(row.rawValue)'s note says to press again but the row is not re-askable")
        }
    }

    // MARK: - the walk

    static let unmetMicrophone = Requirement.microphone(.notDetermined, flavor: flavor)
    static let unmetInputMonitoring = Requirement.inputMonitoring(held: false, accessibilityHeld: true, flavor: flavor)
    static let metAccessibility = Requirement.accessibility(held: true, flavor: flavor)
    static let unmetInputMethod = Requirement.inputMethod(switchedOn: false, flavor: flavor)
    static let readiness = Readiness([unmetMicrophone, unmetInputMonitoring, metAccessibility, unmetInputMethod])

    /// One step at a time, in the list's order, and never a step that is already met.
    @Test func theWalkShowsTheFirstUnmetRequirement() {
        #expect(GuidedSetup().current(in: Self.readiness)?.row == .microphone)
    }

    /// Declining moves the walk on without ending it, and the declined step is the one
    /// the summary brings back.
    @Test func skippingMovesOnAndRevisitingComesBack() {
        var walk = GuidedSetup()
        walk.skip(.microphone)
        #expect(walk.current(in: Self.readiness)?.row == .inputMonitoring)
        walk.skip(.inputMonitoring)
        #expect(walk.current(in: Self.readiness)?.row == .inputMethod)
        walk.skip(.inputMethod)
        #expect(walk.current(in: Self.readiness) == nil)
        walk.revisit(.inputMonitoring)
        #expect(walk.current(in: Self.readiness)?.row == .inputMonitoring)
    }

    /// A grant given in System Settings clears its step at the next reading: the walk keeps
    /// no answer of its own, so a fresh list with the grant met moves it on.
    @Test func aGrantMadeElsewhereClearsItsStepAtTheNextReading() {
        let granted = Readiness([
            .microphone(nil, flavor: Self.flavor), Self.unmetInputMonitoring, Self.metAccessibility, Self.unmetInputMethod,
        ])
        #expect(GuidedSetup().current(in: granted)?.row == .inputMonitoring)
    }

    // MARK: - the rows only the app reads

    /// Each way macOS can withhold the microphone reads as its own word and asks for its
    /// own step; allowed asks for nothing.
    @Test func everyMicrophoneAnswerReadsAsItsOwnWord() {
        let answers: [MicrophoneAuthorization.Withheld?] = [nil] + MicrophoneAuthorization.Withheld.allCases
        let rows = answers.map { Requirement.microphone($0, flavor: Self.flavor) }
        #expect(Set(rows.map(\.reads)).count == answers.count)
        #expect(rows.map(\.met) == [true, false, false, false])
        #expect(Requirement.microphone(.denied, flavor: Self.flavor).step?.contains("Privacy & Security > Microphone") == true)
    }

    /// While Accessibility is off no Input Monitoring dialog can show, so the step points at
    /// Accessibility rather than at a button that cannot work.
    @Test func inputMonitoringWaitsOnAccessibility() {
        let waiting = Requirement.inputMonitoring(held: false, accessibilityHeld: false, flavor: Self.flavor)
        #expect(!waiting.met)
        #expect(waiting.step?.contains("Accessibility") == true)
        #expect(waiting.waitsOn == .accessibility)
        #expect(Requirement.inputMonitoring(held: false, accessibilityHeld: true, flavor: Self.flavor).waitsOn == nil)
    }

    /// Each event-tap grant's step names its own pane and the installation to switch on.
    @Test func anEventTapGrantNamesItsPaneAndTheInstallation() {
        for requirement in [Requirement.inputMonitoring(held: false, accessibilityHeld: true, flavor: Self.flavor), .accessibility(held: false, flavor: Self.flavor)] {
            let step = requirement.step ?? ""
            #expect(step.contains("Privacy & Security > \(requirement.name)"))
            #expect(step.contains(Self.flavor.displayName))
        }
        #expect(Requirement.inputMonitoring(held: true, accessibilityHeld: true, flavor: Self.flavor).met)
    }

    /// The hotkey menu names the grants a source needs from the list itself.
    @Test func aHotkeySourceNamesTheGrantsTheListGivesIt() {
        #expect(HotkeySource.eventTap.asks == "needs Accessibility and Input Monitoring")
        #expect(HotkeySource.registeredHotKey.asks == "needs nothing")
    }
}
