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

    /// Every step says why, what it lets you do, and what happens if you skip it, before
    /// anything is asked of macOS. A step missing any of the three is the unexplained
    /// prompt this setup exists to replace.
    @Test(arguments: Requirement.Row.allCases, Flavor.allCases)
    func everyStepExplainsWhyWhatItEnablesAndWhatSkippingCosts(row: Requirement.Row, flavor: Flavor) {
        let explanation = row.explanation(for: flavor)
        for (part, text) in [("why", explanation.why), ("enables", explanation.enables), ("if skipped", explanation.ifSkipped)] {
            #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(row.rawValue) has no \(part)")
        }
    }

    /// A step that names the app names the installation it is shown in, in every part of
    /// its explanation. "LowTalker Dev" contains "LowTalker", so containment alone would
    /// pass a part hardcoding the release name; a part that names the app is required to
    /// differ between the two instead.
    @Test func aStepNamingTheAppNamesTheInstallationItIsShownIn() {
        let parts: [(name: String, of: (Explanation) -> String)] = [("why", \.why), ("enables", \.enables), ("if skipped", \.ifSkipped)]
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
        #expect(asking == [.microphone, .accessibility, .inputMethod, .keyboardHelper])
        for row in asking { #expect(row.askTitle?.hasSuffix("…") == true, "\(row.rawValue)'s button does not say a dialog follows") }
    }

    /// Every grant a person can switch by hand has the pane it is switched in, which is
    /// where a person goes after declining a dialog macOS will not show twice.
    @Test func everyGrantOpensTheExactPaneItIsSwitchedIn() {
        #expect(Requirement.Row.microphone.settingsPane?.absoluteString.hasSuffix("Privacy_Microphone") == true)
        #expect(Requirement.Row.accessibility.settingsPane?.absoluteString.hasSuffix("Privacy_Accessibility") == true)
        #expect(Requirement.Row.inputMethod.settingsPane?.absoluteString.hasSuffix("com.apple.Keyboard-Settings.extension") == true)
        #expect(Requirement.Row.driverExtension.settingsPane?.absoluteString.hasSuffix("com.apple.LoginItems-Settings.extension") == true)
        #expect(Requirement.Row.keyboardHelper.settingsPane?.absoluteString.hasSuffix("com.apple.LoginItems-Settings.extension") == true)
        #expect(Requirement.Row.keyboardSetupAssistant.settingsPane == nil)
    }

    // MARK: - the walk

    static let unmetMicrophone = Requirement.microphone(.notDetermined, flavor: flavor)
    static let unmetAccessibility = Requirement.accessibility(held: false, flavor: flavor)
    static let metInputMethod = Requirement.inputMethod(switchedOn: true, flavor: flavor)
    static let unmetHelper = Requirement(row: .keyboardHelper, reads: "not registered", step: "Allow it.")
    static let readiness = Readiness([unmetMicrophone, unmetAccessibility, metInputMethod, unmetHelper])

    /// One step at a time, in the list's order, and never a step that is already met.
    @Test func theWalkShowsTheFirstUnmetRequirement() {
        #expect(GuidedSetup().current(in: Self.readiness)?.row == .microphone)
    }

    /// Declining moves the walk on without ending it, and the declined step is the one
    /// the summary brings back.
    @Test func skippingMovesOnAndRevisitingComesBack() {
        var walk = GuidedSetup()
        walk.skip(.microphone)
        #expect(walk.current(in: Self.readiness)?.row == .accessibility)
        walk.skip(.accessibility)
        #expect(walk.current(in: Self.readiness)?.row == .keyboardHelper)
        walk.skip(.keyboardHelper)
        #expect(walk.current(in: Self.readiness) == nil)
        walk.revisit(.accessibility)
        #expect(walk.current(in: Self.readiness)?.row == .accessibility)
    }

    /// A grant given in System Settings clears its step at the next reading: the walk keeps
    /// no answer of its own, so a fresh list with the grant met moves it on.
    @Test func aGrantMadeElsewhereClearsItsStepAtTheNextReading() {
        let granted = Readiness([
            .microphone(nil, flavor: Self.flavor), Self.unmetAccessibility, Self.metInputMethod, Self.unmetHelper,
        ])
        #expect(GuidedSetup().current(in: granted)?.row == .accessibility)
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

    /// The event tap's grant step names its own pane and the installation to switch on.
    @Test func theEventTapGrantNamesItsPaneAndTheInstallation() {
        let step = Self.unmetAccessibility.step ?? ""
        #expect(step.contains("Privacy & Security > Accessibility"))
        #expect(step.contains(Self.flavor.displayName))
        #expect(Requirement.accessibility(held: true, flavor: Self.flavor).met)
    }

    /// The hotkey menu names the grants a source needs from the list itself.
    @Test func aHotkeySourceNamesTheGrantsTheListGivesIt() {
        #expect(HotkeySource.eventTap.asks == "needs Accessibility")
        #expect(HotkeySource.registeredHotKey.asks == "needs nothing")
    }
}
