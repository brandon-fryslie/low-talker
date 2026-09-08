import DriverExtension
import Testing
@testable import Onboarding

/// The list a person acts on. What is checked is the contract every surface depends on -
/// that a requirement carries a step exactly when something is left to do, that no state
/// is left without one, and that a fact nobody could read never reads as fine.
/// [LAW:behavior-not-structure]
@Suite struct RequirementTests {
    static let service = "com.lowtalker.keyboardd"
    static let devLabel = "com.lowtalker.keyboardd.dev"

    // MARK: - the driver extension

    /// The two states macOS reaches once the user has done their part, and the only two
    /// that ask for nothing. `running` additionally means a client has opened the driver,
    /// which is not something anyone can be told to do.
    @Test func onlyAnEnabledDriverAsksNothingOfAnyone() {
        for state in DriverState.allCases {
            let nothingToDo = Requirement.driverExtension(state).met
            #expect(nothingToDo == (state == .enabled || state == .running), "\(state.rawValue)")
        }
    }

    /// Every word the probe can return has a step of its own. A state that fell through
    /// to a shared "the driver is not ready" would send a Mac needing an install and a
    /// Mac needing a restart the same way.
    @Test func everyDriverStateThatNeedsSomethingSaysWhat() {
        for state in DriverState.allCases where state != .enabled && state != .running {
            let step = Requirement.driverExtension(state).step
            #expect(step?.isEmpty == false, "\(state.rawValue) carries no step")
        }
    }

    /// The three states that need a person at System Settings send them to the one pane
    /// that has both approvals in it, and name the extension they are turning on.
    @Test func theStatesNeedingAClickNameThePaneAndTheExtension() {
        for state in [DriverState.awaitingApproval, .disabled] {
            let step = Requirement.driverExtension(state).step ?? ""
            #expect(step.contains("Login Items & Extensions"))
            #expect(step.contains(DriverProbe.bundleID))
        }
    }

    /// A state nobody could read is never dressed up as a step to take. It points at the
    /// verb that says what could not be read. [LAW:no-silent-failure]
    @Test func anUnreadableDriverPointsAtWhatWouldSayWhy() {
        let step = Requirement.driverExtension(.unknown).step ?? ""
        #expect(step.contains("virtual-hid-driver state"))
    }

    /// A state a command can repair names the command that repairs it. `state` takes a
    /// reading and changes nothing, so a step promising a repair has to say it in the
    /// verbs that perform one - which a step merely being non-empty cannot tell apart.
    @Test func everyStateAScriptCanRepairNamesTheVerbsThatRepairIt() {
        let repairs: [(DriverState, [String])] = [
            (.absent, ["virtual-hid-driver install"]),
            (.installedInactive, ["virtual-hid-driver install"]),
            (.residue, ["virtual-hid-driver remove", "virtual-hid-driver install"]),
        ]
        for (state, verbs) in repairs {
            let step = Requirement.driverExtension(state).step ?? ""
            for verb in verbs {
                #expect(step.contains(verb), "\(state.rawValue) never names `\(verb)`")
            }
        }
    }

    /// The reading is shown whatever it is, so a report says what it saw and not only
    /// what it wants done.
    @Test func everyDriverStateReadsBackAsItsOwnWord() {
        for state in DriverState.allCases {
            #expect(Requirement.driverExtension(state).reads == state.rawValue)
        }
    }

    // MARK: - the keyboard helper

    /// Holding the Mach service is the only standing that means the helper will answer.
    /// In particular, a job that is loaded and running but lost the name is not ready -
    /// that is the whole failure this requirement exists to catch.
    @Test func onlyAHelperHoldingTheServiceIsReady() {
        for standing in HelperStanding.allCases {
            let requirement = Requirement.keyboardHelper(standing, serviceName: Self.service, developmentLabel: Self.devLabel)
            #expect(requirement.met == (standing == .holdingTheService), "\(standing)")
        }
    }

    /// The list `make check-docs` holds README to is the vocabulary the row actually
    /// prints, and no two standings share a line of it.
    ///
    /// Both halves are load-bearing. If the list stopped being derived from the row, the
    /// check would prove README agreed with a list nobody reads. And a reading is how a
    /// person - or an agent grepping the log, which is the only way to read the menu
    /// without a screen - tells one standing from another, so two standings printing one
    /// string would put back exactly the ambiguity that splitting them removed, while
    /// leaving README and the enum in perfect agreement about it.
    @Test func everyStandingReadsBackAsItsOwnLineAndNoTwoShareOne() {
        #expect(Requirement.helperReadings == HelperStanding.allCases.map {
            Requirement.keyboardHelper($0, serviceName: Self.service, developmentLabel: Self.devLabel).reads
        })
        #expect(Set(Requirement.helperReadings).count == HelperStanding.allCases.count)
    }

    /// An app whose helper is enabled while another job holds the name reports enabled
    /// and types nothing. The step has to name the other job, because nothing else on
    /// the Mac will: launchd does not make the loser loud.
    @Test func aServiceLostToTheDevelopmentJobNamesItAndTheRemoval() {
        let step = Requirement.keyboardHelper(.theDevelopmentJobHoldsTheService, serviceName: Self.service, developmentLabel: Self.devLabel).step ?? ""
        #expect(step.contains(Self.devLabel))
        #expect(step.contains("keyboard-helper uninstall"))
    }

    /// A holder that was never identified is never reported as one that was. Naming the
    /// development job here would send a reader to a command that removes a job this Mac
    /// does not have, and leave the job that actually holds the name in place.
    @Test func aServiceLostToAnUnidentifiedJobNamesNeitherThatJobNorItsRemoval() {
        let step = Requirement.keyboardHelper(.anotherJobHoldsTheService, serviceName: Self.service, developmentLabel: Self.devLabel).step ?? ""
        #expect(!step.contains(Self.devLabel))
        #expect(!step.contains("keyboard-helper uninstall"))
        #expect(step.contains("/Library/LaunchDaemons"))
    }

    @Test func aHelperWaitingForItsApprovalIsSentToLoginItems() {
        let step = Requirement.keyboardHelper(.awaitingApproval, serviceName: Self.service, developmentLabel: Self.devLabel).step ?? ""
        #expect(step.contains("Login Items & Extensions"))
    }

    /// launchd holds no job whether the helper was never registered or is registered and
    /// waiting for its click, so only the app - which can put the question to
    /// SMAppService - can tell them apart, and only when it has an answer.
    @Test func onlyTheAppsOwnRegistrationTellsNoJobFromAwaitingApproval() {
        #expect(HelperStanding.noJob.sharpenedByTheAppsOwnRegistration(approvalPending: true) == .awaitingApproval)
        #expect(HelperStanding.noJob.sharpenedByTheAppsOwnRegistration(approvalPending: false) == .noJob)
    }

    /// Sharpening only ever answers the question launchd could not. A helper that is
    /// answering, or one that lost the name, is a reading launchd took itself, and no
    /// pending approval may overwrite it.
    @Test func sharpeningNeverOverwritesAReadingLaunchdCouldTake() {
        for standing in HelperStanding.allCases where standing != .noJob {
            #expect(standing.sharpenedByTheAppsOwnRegistration(approvalPending: true) == standing, "\(standing)")
        }
    }

    // MARK: - the Keyboard Setup Assistant

    /// Not an approval, and the one thing here that appears on first use: an unanswered
    /// assistant takes the first dictation's keystrokes. The step has to carry the write
    /// that stops it, aimed at this device's own key.
    @Test func anUnansweredAssistantCarriesTheWriteThatSuppressesIt() {
        let key = VirtualKeyboardIdentity.keyboardTypeKey
        let requirement = Requirement.keyboardSetupAssistant(answered: false, key: key, path: "/Library/Preferences/com.apple.keyboardtype")
        let step = requirement.step ?? ""
        #expect(step.contains(key))
        #expect(step.contains("/Library/Preferences/com.apple.keyboardtype"))
        #expect(step.contains("\(VirtualKeyboardIdentity.ansiKeyboardType)"))
    }

    /// The key is `<product>-<vendor>-<country>`, which is not the order the device is
    /// initialised in. Getting it backwards writes an entry for a device that does not
    /// exist and leaves the assistant returning on every run.
    @Test func theCacheKeyIsProductThenVendorThenCountry() {
        #expect(VirtualKeyboardIdentity.keyboardTypeKey == "10203-5824-0")
    }

    @Test func anAnsweredAssistantAsksNothing() {
        #expect(Requirement.keyboardSetupAssistant(answered: true, key: "k", path: "/p").met)
    }

    // MARK: - the list

    /// A fact nobody could read never counts as met, so a report cannot come out ready
    /// on the strength of a reading nobody took. [LAW:no-silent-failure]
    @Test func aRequirementThatCouldNotBeReadIsNeverMet() {
        let requirement = Requirement.unreadable("Driver extension", OnboardingUnreadable.plistUnreadable(path: "/p", reason: "why"))
        #expect(!requirement.met)
        #expect(requirement.step?.contains("why") == true)
        #expect(!Readiness([requirement]).ready)
    }

    /// Every requirement is shown every time, met ones included: a list that printed only
    /// what was wrong would leave a reader unable to tell "checked and fine" from "never
    /// checked". [LAW:dataflow-not-control-flow]
    @Test func theListShowsEveryRequirementWhetherOrNotItNeedsAnything() {
        let readiness = Readiness([
            .driverExtension(.running),
            .keyboardHelper(.holdingTheService, serviceName: Self.service, developmentLabel: Self.devLabel),
        ])
        #expect(readiness.ready)
        #expect(readiness.description.contains("Driver extension: running"))
        #expect(readiness.description.contains("Keyboard helper: answering"))
    }

    @Test func oneUnmetRequirementIsEnoughToStopTheList() {
        let readiness = Readiness([
            .driverExtension(.running),
            .keyboardHelper(.anotherJobHoldsTheService, serviceName: Self.service, developmentLabel: Self.devLabel),
        ])
        #expect(!readiness.ready)
    }
}
