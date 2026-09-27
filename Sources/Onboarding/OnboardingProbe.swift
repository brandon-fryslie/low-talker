import Choices
import DriverExtension
import Flavors
import Foundation
import Grants
import InputSource
import KeyboardService

/// Reading this Mac for the two facts onboarding takes for itself: which launchd job
/// holds the helper's Mach service, and whether Keyboard Setup Assistant already has an
/// answer for the virtual keyboard.
///
/// [LAW:effects-at-boundaries] Both are effects, and both are separated from the pure
/// mapping that turns them into a `Requirement`, so the steps can be asserted as values
/// on a Mac that is in none of the states worth checking.
public enum OnboardingProbe {
    /// Where this flavor's helper stands, asked of the one label that can hold it.
    ///
    /// Read without root on purpose: the menu-bar app is not root and this is its question.
    ///
    /// One question and no second reading, because there is no second label to ask about.
    /// A flavor's launchd job and its Mach service carry one name, so a second *bootstrap*
    /// under that label is refused outright (exit 5, measured). What that refusal does not
    /// cover is the app's own path in: `SMAppService.register()` is not `bootstrap`, so a
    /// plist job already holding the label simply stays, and the app's registration never
    /// becomes the running job. That is a reading of its own, and this tells it apart from
    /// a holder outside launchd by the field launchd answers with.
    /// [LAW:no-silent-failure]
    public static func helperStanding(flavor: Flavor) throws -> HelperStanding {
        try standing(
            from: Command("/bin/launchctl", "print", "system/\(flavor.launchdLabel)").run(),
            flavor: flavor, installation: Carrier.installation(of:))
    }

    /// What launchd said, read.
    ///
    /// A job launchd has never heard of is a normal answer and the one this returns
    /// `noJob` for. Any other failure is refused: an unread launchd reported as "no job"
    /// would send a reader to approve a login item that is already approved.
    /// [LAW:no-silent-failure]
    ///
    /// - Parameter installation: which installation an executable belongs to, handed in so
    ///   the bundle it reads off the disk is the caller's. [LAW:effects-at-boundaries]
    static func standing(from printed: Command.Output, flavor: Flavor, installation: (URL) -> Flavor?) throws -> HelperStanding {
        guard let job = try HelperJob.Record(printed, label: flavor.launchdLabel, service: flavor.machServiceName) else { return .noJob }
        // A job loaded from a plist in /Library/LaunchDaemons is not the app's
        // registration, and `SMAppService.register()` gets no refusal while it holds the
        // label: the app's own copy simply never spawns. That is harmless when the plist
        // runs a helper this installation shipped and holds the service - the job
        // `lowtalker helper install` loads - and it is the stray the step removes when it
        // runs anything else, such as a checkout's build under the release label.
        // [LAW:single-enforcer] The same rule install keeps, so the reading does not
        // depend on which copy of the CLI is asking.
        guard job.loadedFromLaunchDaemons else {
            return job.holdsTheService ? .holdingTheService : .anotherJobHoldsTheService
        }
        return job.program.flatMap(installation) == flavor && job.holdsTheService
            ? .answeringAsALaunchDaemon : .aBootstrappedJobHoldsTheLabel
    }

    /// Whether Keyboard Setup Assistant already holds a verdict for this keyboard.
    ///
    /// The file is world-readable, so this needs no privilege. Writing it does, which is
    /// the keyboard helper's job as it starts - this is the reading that says the helper
    /// got there, and the row it feeds stays unmet until it has. [LAW:one-source-of-truth]
    /// One file and one key, both named by `VirtualKeyboardIdentity`, so the reader here
    /// and the writer in the helper cannot come to mean different files.
    public static func keyboardSetupAssistantAnswered(
        key: String = VirtualKeyboardIdentity.keyboardTypeKey,
        at path: String = VirtualKeyboardIdentity.keyboardTypePlist
    ) throws -> Bool {
        // A Mac that has never met any keyboard has no file, and that is an answer: the
        // assistant has nothing cached. Told apart from a file that is there and cannot
        // be read, which is not. [LAW:no-silent-failure]
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let contents: Any
        do {
            contents = try PropertyListSerialization.propertyList(
                from: try Data(contentsOf: URL(fileURLWithPath: path)), options: [], format: nil)
        } catch {
            throw OnboardingUnreadable.plistUnreadable(path: path, reason: "\(error)")
        }
        guard let root = contents as? [String: Any] else {
            throw OnboardingUnreadable.plistUnreadable(path: path, reason: "its root is not a dictionary")
        }
        // A file with no `keyboardtype` dictionary is one the assistant has not written
        // to yet, which is the same answer as no file at all.
        guard let cached = root["keyboardtype"] else { return false }
        guard let answers = cached as? [String: Any] else {
            throw OnboardingUnreadable.plistUnreadable(path: path, reason: "its keyboardtype entry is not a dictionary")
        }
        return answers[key] != nil
    }
}

/// Who is reading the list, which decides what can be read at all.
public enum OnboardingReader: Sendable, Hashable {
    /// The app itself, which holds its own privacy grants and its own `SMAppService`
    /// registration, and so can read every row.
    ///
    /// - Parameter helperAwaitingApproval: what `SMAppService` told the app about the
    ///   helper's registration. See `HelperStanding.sharpenedByTheAppsOwnRegistration`.
    /// - Parameter privacy: the app's grants, read fresh; see `PrivacyReading`.
    case theApp(helperAwaitingApproval: Bool, privacy: Result<PrivacyReading, PrivacyReadingFailure>)
    /// Any other process - the CLI. It reads what belongs to the Mac and names the rows
    /// that belong to the app, unread. See `Requirement.Row.readOnlyByTheApp`.
    case elsewhere

    /// What this reader can say about the helper's registration: nil from a reader that
    /// has none to ask about, which is not the same as "not waiting".
    var helperAwaitingApproval: Bool? {
        switch self {
        case .theApp(let waiting, _): waiting
        case .elsewhere: nil
        }
    }

    /// The grants, as far as this reader has them. `canRead` keeps the rows that need them
    /// from any other reader, so the failure here is never shown; it is a failure rather
    /// than a guess so that a row reaching it anyway says so. [LAW:no-silent-failure]
    var privacy: Result<PrivacyReading, PrivacyReadingFailure> {
        switch self {
        case .theApp(_, let privacy): privacy
        case .elsewhere: .failure(PrivacyReadingFailure("only the app reads its own grants"))
        }
    }

    func canRead(_ row: Requirement.Row) -> Bool {
        switch self {
        case .theApp: true
        case .elsewhere: !row.readOnlyByTheApp
        }
    }
}

public extension OnboardingProbe {
    /// The rows a setup needs: a choice not made yet could go either way, so it counts
    /// every answer to it. [LAW:one-source-of-truth] The app asks this too, before deciding
    /// whether to check Accessibility at all.
    static func needed(delivery: Delivery?, source: HotkeySource?) -> [Requirement.Row] {
        let deliveries: [Delivery] = delivery.map { [$0] } ?? Delivery.allCases
        let sources: [HotkeySource] = source.map { [$0] } ?? HotkeySource.allCases
        return Requirement.Row.allCases.filter { $0.isNeeded(deliveries: deliveries, sources: sources) }
    }

    /// Everything that must hold before low-talker can hear and type, read off this Mac now.
    ///
    /// The list is assembled here and nowhere else. `lowtalker onboard`, the menu-bar app
    /// and its guided setup are views of one list rather than lists that happen to agree,
    /// and a surface that built its own would drift the first time a requirement was added
    /// to only one of them. [LAW:one-source-of-truth]
    ///
    /// Reading never asks: nothing here can put a system dialog on screen, which is what
    /// lets the app read the list at launch and every time its menu opens.
    ///
    /// - Parameter flavor: which installation is being read. The two run side by side and
    ///   each has its own helper, service, label and grants, so every reading below is a
    ///   reading about one of them and there is no such thing as the readiness of "the app".
    /// - Parameter delivery: the delivery chosen, or nil for a choice not made yet.
    /// - Parameter source: the hotkey source chosen, or nil the same way.
    ///
    /// [LAW:one-source-of-truth] A choice not made yet could go either way, so it reads the
    /// rows of every answer to it. That rule is written here once, for the app and the CLI
    /// alike.
    /// - Parameter reader: who is asking, which decides the rows only the app can read.
    /// - Parameter cli: the lowtalker binary the driver's steps name; see
    ///   `Requirement.driverExtension(_:cli:)`.
    static func readiness(
        flavor: Flavor, delivery: Delivery?, source: HotkeySource?, reader: OnboardingReader, cli: String
    ) -> Readiness {
        let needed = needed(delivery: delivery, source: source)
        // The helper's standing is read at most once and only if asked for, because two
        // rows want it: its own, and the assistant's, whose step depends on whether a
        // helper has run. The dependency is in the data rather than in the order the rows
        // happen to be read in. [LAW:no-ambient-temporal-coupling]
        lazy var helper = helperRow(flavor: flavor, approvalPending: reader.helperAwaitingApproval, cli: cli)
        var requirements: [Requirement] = []
        for row in needed where reader.canRead(row) {
            switch row {
            case .microphone:
                requirements.append(.privacy(.microphone, reader.privacy, flavor: flavor) { reading in
                    let withheld: MicrophoneAuthorization.Withheld? = switch reading.microphoneAuthorization {
                    case .granted: nil
                    case .withheld(let reason): reason
                    }
                    return .microphone(withheld, flavor: flavor)
                })
            case .inputMonitoring:
                requirements.append(.privacy(.inputMonitoring, reader.privacy, flavor: flavor) {
                    // Accessibility is read whenever this row is: both serve the event tap.
                    .inputMonitoring(held: $0.inputMonitoring == .granted, accessibilityHeld: $0.accessibility == true, flavor: flavor)
                })
            case .accessibility:
                requirements.append(.privacy(.accessibility, reader.privacy, flavor: flavor) {
                    .accessibility(held: $0.accessibility == true, flavor: flavor)
                })
            case .inputMethod:
                requirements.append(.inputMethod(switchedOn: InputSourceInstaller.isSwitchedOn(flavor), flavor: flavor))
            case .driverExtension:
                requirements.append(driverRow(cli: cli))
            case .keyboardHelper:
                requirements.append(helper.row)
            case .keyboardSetupAssistant:
                requirements.append(keyboardSetupAssistantRow(flavor: flavor, aHelperHasRun: helper.aHelperHasRun))
            }
        }
        return Readiness(requirements, notReadHere: needed.filter { !reader.canRead($0) })
    }

    /// Each reading is taken and turned into its row here, at the edge, and a reading
    /// that failed becomes a row saying so rather than ending the report: three
    /// requirements a reader could have acted on are worth more than one error.
    /// [LAW:effects-at-boundaries]
    private static func driverRow(cli: String) -> Requirement {
        do { return .driverExtension(DriverState(try DriverProbe.facts()), cli: cli) }
        catch { return .unreadable(.driverExtension, error) }
    }

    /// The helper's row, and the one thing about it the assistant's row needs.
    ///
    /// What that one thing is, `HelperStanding` says: this asks the standing rather than
    /// comparing it here, so the question "has a helper already had its chance to file
    /// the answer" has one answer and it lives with the states it is about.
    /// [LAW:one-source-of-truth]
    ///
    /// A reading that failed answers `false`, which is not that reading collapsing into a
    /// wrong one: it is the only honest thing to hand a row asking whether a helper ran,
    /// when nobody could look. What could not be read is loud in the row this returns
    /// beside it - the helper's own, which reads `could not be read` and names the
    /// reason - so the failure is reported where it belongs rather than inferred from the
    /// assistant's step. [LAW:no-silent-failure]
    private static func helperRow(flavor: Flavor, approvalPending: Bool?, cli: String) -> (row: Requirement, aHelperHasRun: Bool) {
        do {
            let standing = try helperStanding(flavor: flavor)
                .sharpenedByTheAppsOwnRegistration(approvalPending: approvalPending)
            return (.keyboardHelper(standing, flavor: flavor, cli: cli), standing.aHelperHasRun)
        } catch { return (.unreadable(.keyboardHelper, error), false) }
    }

    private static func keyboardSetupAssistantRow(flavor: Flavor, aHelperHasRun: Bool) -> Requirement {
        do {
            return .keyboardSetupAssistant(
                answered: try keyboardSetupAssistantAnswered(),
                aHelperHasRun: aHelperHasRun,
                helperSubsystem: flavor.machServiceName)
        } catch { return .unreadable(.keyboardSetupAssistant, error) }
    }
}

/// Why a reading onboarding needed could not be taken. Never a standing: "I could not
/// look" and "here is where it stands" are different facts. [LAW:no-silent-failure]
public enum OnboardingUnreadable: Error, CustomStringConvertible, Equatable {
    case launchdRefused(label: String, status: Int32, complaint: String)
    case plistUnreadable(path: String, reason: String)
    case noPath(label: String, record: String)

    public var description: String {
        switch self {
        case .launchdRefused(let label, let status, let complaint):
            "could not read what launchd holds for \(label): `launchctl print` exited \(status)\(complaint.isEmpty ? "" : ": \(complaint)")"
        case .plistUnreadable(let path, let reason):
            "could not read \(path): \(reason)"
        case .noPath(let label, let record):
            "launchd reports a job under \(label) with no path, so who holds it is unknown: \(record)"
        }
    }
}
