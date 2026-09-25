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
