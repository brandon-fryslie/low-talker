import ArgumentParser
import DriverExtension
import Flavors
import Foundation
import KeyboardLayout
import KeyboardService
import LowTalkerCore
import Onboarding
import Typing

/// Performs a list of actions the way the app does: text typed and chords pressed on the
/// virtual keyboard, clicks and scrolls made with the virtual mouse, both through the
/// installed helper, into one app raised first.
///
/// [LAW:one-source-of-truth] `act`, `type` and `keys` differ only in where their actions
/// come from - JSON on stdin, a string, chord spellings - so each builds its list and hands
/// it here, and the three are one insertion path with one exit contract. The executor is
/// built through `Executor.guarding`, the way the app and `dictate` build theirs, so what
/// a script types lands exactly the way dictation does.
@MainActor
enum Performance {
    static func perform(_ actions: [Action], in app: BundleID, on layout: KeyboardLayout, flavor: Flavor) async throws {
        do {
            // Watched before a single report goes out, so there is no window where an
            // interrupt can end the process with a key already down.
            let interrupt = Interrupt.watched()
            // One connection for every action, held open across them: the helper answers a
            // lazy connection's first call after launchd has started the job, and that is a
            // cost to pay once and not per action.
            let helper = HelperConnection(flavor: flavor)
            let executor = Executor.guarding(keyboard: helper.keyboard, mouse: helper.mouse, interrupt: interrupt)
            // The app types into whatever was in front when the hotkey went down. Here the
            // shell was, so the app is brought forward first - a no-op when it is the shell -
            // and a run whose app will not come is refused before a key goes down.
            try await TargetApp(bundleID: app, interrupt: interrupt).raise(within: .seconds(5))
            // There was no key-up: the actions were handed over, and the moment they were
            // stands in for it, so the number printed is the executor's own time.
            for performed in try await executor.perform(actions, in: app, on: layout, since: ContinuousClock.now) {
                print(performed)
            }
        } catch {
            throw PerformExit.fail(error, flavor: flavor)
        }
    }
}

/// The app a typing command acts on.
struct TargetOption: ParsableArguments {
    @Option(
        name: .customLong("into"),
        help: "The bundle id of the app to act in, raised first. Defaults to the app in front when the command starts, which from a terminal is the terminal.")
    var stated: BundleID?

    /// [LAW:one-source-of-truth] The app in front is macOS's to say, so it is read rather
    /// than asked for when it is the one meant.
    @MainActor
    func app() throws -> BundleID { try stated ?? TargetApp.frontmost() }
}

/// What `act`, `type` and `keys` exit with when they do not finish: a code for each
/// failure a script can do something about, and 1 for the rest.
///
/// [CLI] The code is the contract and stderr is the account. Each of these is a different
/// thing to do next - change the text, approve the helper, activate the driver - which is
/// why they are not one code. Usage errors are ArgumentParser's 64.
enum PerformExit: Int32, CaseIterable {
    case untypeable = 3
    case helperNotApproved = 4
    case driverNotActivated = 5

    var meaning: String {
        switch self {
        case .untypeable: "the text or a chord cannot be typed here: a character the keyboard layout has no keys for, a chord the device cannot press, or one that would press a hotkey. Nothing was typed."
        case .helperNotApproved: "the keyboard helper could not be reached and this installation's helper is not the one answering: not registered, not approved, or displaced. `lowtalker onboard` names the step."
        case .driverNotActivated: "the keyboard helper could not be reached and the driver extension is not activated, so no helper can type. `lowtalker onboard` names the step."
        }
    }

    /// The exit codes as `--help` lists them, from the cases themselves.
    static let discussion = discussion(for: allCases, success: "Exits 0 when every action was performed")

    /// The exit codes a command can end with, for a command that can end with only some.
    static func discussion(for codes: [PerformExit], success: String) -> String {
        ([success + ", and otherwise:"]
            + codes.map { "  \($0.rawValue)  \($0.meaning)" }
            + ["  1  anything else, such as focus moving mid-run or an interrupt, said on stderr with how much landed."])
            .joined(separator: "\n")
    }

    /// [LAW:dataflow-not-control-flow] Every failure leaves the same way: said on stderr,
    /// then the code its kind is owed. A failure this names nothing about exits 1, as
    /// ArgumentParser's own would.
    static func fail(_ error: any Error, flavor: Flavor) -> ExitCode {
        let failure = classify(error, flavor: flavor, machine: .of(flavor), cli: LowTalker.path)
        FileHandle.standardError.write(Data("Error: \(failure.said)\n".utf8))
        return ExitCode(failure.exit?.rawValue ?? ExitCode.failure.rawValue)
    }

    /// A failure's code and the account of it for stderr.
    ///
    /// The helper's wire is what says whether typing works, so nothing is read before it is
    /// tried: a reading beforehand would be a second answer, and wrong in both directions -
    /// Keyboard Setup Assistant's row is unmet on a Mac that types fine. Only once the wire
    /// has said the helper is unreachable is the machine read, to say why, and the row that
    /// is not met is printed with its step. [LAW:single-enforcer] Whether a row is met is the
    /// row's own answer, not a second rule kept here.
    ///
    /// The rows are read in the order their steps come: no helper can type without the
    /// driver, so a Mac missing both is a Mac whose next step is the driver. Each is read
    /// only once every row before it is met, so a reading that fails costs the code only
    /// when it is the one that decides it.
    static func classify(_ error: any Error, flavor: Flavor, machine: Machine, cli: String) -> (exit: PerformExit?, said: String) {
        let causes = error.causes
        if causes.contains(where: { $0 is UntypeableCharacters || $0 is UnpressableChord || $0 is WouldPressTheHotkey }) {
            return (.untypeable, "\(error)")
        }
        guard causes.contains(where: { $0 is HelperConnection.Unreachable }) else { return (nil, "\(error)") }
        let rows: [(PerformExit, () throws -> Requirement)] = [
            (.driverNotActivated, { .driverExtension(try machine.driver(), cli: cli) }),
            (.helperNotApproved, { .keyboardHelper(try machine.helper(), flavor: flavor) }),
        ]
        for (exit, row) in rows {
            let requirement: Requirement
            do { requirement = try row() } catch let unread {
                // [LAW:no-silent-failure] The code stays 1 rather than guessing a cause.
                return (nil, "\(error)\nwhy the helper could not be reached was not read: \(unread)")
            }
            if !requirement.met { return (exit, "\(error)\n\(requirement)") }
        }
        return (nil, "\(error)")
    }
}

/// The two readings that say why a helper cannot be reached, each taken when asked for.
struct Machine {
    let driver: () throws -> DriverState
    let helper: () throws -> HelperStanding

    static func of(_ flavor: Flavor) -> Machine {
        Machine(
            driver: { DriverState(try DriverProbe.facts()) },
            helper: { try OnboardingProbe.helperStanding(label: flavor.launchdLabel, service: flavor.machServiceName) })
    }
}
