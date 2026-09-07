import ArgumentParser
import DriverExtension
import Foundation
import KeyboardService
import Onboarding

/// Everything that must hold before low-talker can type, read off this Mac, with the
/// step for whatever is missing.
///
/// The menu-bar app shows this same list in these same words - the app is the surface
/// the onboarding ticket is about, and this is how an agent reads it back without a
/// screen. What the app can say and this cannot is its own Login Items approval:
/// `SMAppService` answers only the bundle that asks, so from here launchd's "no job"
/// covers both a helper never registered and one registered and waiting for its click.
struct OnboardCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "onboard",
        abstract: "Print everything that must hold before low-talker can type, and the step for whatever is missing.",
        discussion: """
            Exits 0 when nothing is left to do and 2 when something is. A fact that could \
            not be read is a row of its own naming why, and it never counts as met.
            """
    )

    func run() throws {
        let readiness = Readiness(driver() + helper() + keyboardAssistant())
        print(readiness)
        // The code is a value computed the one way every time, rather than an exit taken
        // on some runs and not others. [LAW:dataflow-not-control-flow]
        throw ExitCode(readiness.ready ? 0 : 2)
    }

    /// Each reading is taken and turned into its row here, at the edge, and a reading
    /// that failed becomes a row saying so rather than ending the report: three
    /// requirements a reader could have acted on are worth more than one error.
    /// [LAW:effects-at-boundaries]
    private func driver() -> [Requirement] {
        do { return [.driverExtension(DriverState(try DriverProbe.facts()))] }
        catch { return [.unreadable("Driver extension", error)] }
    }

    private func helper() -> [Requirement] {
        do {
            let standing = try OnboardingProbe.helperStanding(label: Helper.launchdLabel, service: Helper.machServiceName)
            return [.keyboardHelper(standing, serviceName: Helper.machServiceName, developmentLabel: Helper.developmentLabel)]
        } catch { return [.unreadable("Keyboard helper", error)] }
    }

    private func keyboardAssistant() -> [Requirement] {
        do {
            return [.keyboardSetupAssistant(
                answered: try OnboardingProbe.keyboardSetupAssistantAnswered(),
                key: VirtualKeyboardIdentity.keyboardTypeKey,
                path: OnboardingProbe.keyboardTypeDomain
            )]
        } catch { return [.unreadable("Keyboard Setup Assistant", error)] }
    }
}
