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
    public static func helperStanding(label: String, service: String) throws -> HelperStanding {
        try standing(
            from: Command("/bin/launchctl", "print", "system/\(label)").run(),
            label: label, service: service)
    }

    /// What launchd said, read.
    ///
    /// A job launchd has never heard of is a normal answer and the one this returns
    /// `noJob` for. Any other failure is refused: an unread launchd reported as "no job"
    /// would send a reader to approve a login item that is already approved.
    /// [LAW:no-silent-failure]
    static func standing(from printed: Command.Output, label: String, service: String) throws -> HelperStanding {
        guard printed.status == 0 else {
            guard printed.merged.contains("Could not find service") else {
                throw OnboardingUnreadable.launchdRefused(label: label, status: printed.status, complaint: printed.merged)
            }
            return .noJob
        }
        // [LAW:parse-dont-validate] Whose job this is, read off the one field that separates
        // the two ways a job reaches this label. Measured on this Mac, 2026-09-12, against
        // the running release app and its plist-installed counterpart:
        //
        //   SMAppService:              path = (submitted by smd.919)
        //   launchctl bootstrap:       path = /Library/LaunchDaemons/<label>.plist
        //
        // Read before the endpoint, not after: a plist job under this label carries the
        // service in its own MachServices, so it names the endpoint exactly as the app's
        // job would - and a reading that asked about the endpoint first would call it
        // "answering" and never reach here. Whatever it holds, it is not the app's
        // registration, and its plist is the thing that has to go.
        //
        // The value must *start* there, as the script's `/Library/LaunchDaemons/*` does: the
        // app's own plist sits under `Contents/Library/LaunchDaemons/` in its bundle, and a
        // match anywhere in the line would call the app's job a stray one. The line must be
        // the job's own `path`, not a `stderr path` nested beneath it. [LAW:single-enforcer]
        let path = printed.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("path = ") }?
            .dropFirst("path = ".count) ?? ""
        guard !path.hasPrefix("/Library/LaunchDaemons/") else { return .aBootstrappedJobHoldsTheLabel }
        // The endpoint is handed out at load, so a job that holds the service names it
        // here. A job that asked and lost simply has no such line: launchd does not make
        // the loser loud, which is exactly why this is read rather than assumed.
        //
        // At load, and not at check-in - which is the whole reason this reads the
        // endpoints block rather than a state field, and is worth recording because it is
        // the reading that looks wrong. Measured with a job whose program is `sleep`, so
        // it never checks a Mach service in at all: `state = running`, and the endpoint
        // already named, with `active = 0`. Check-in is what `active` tracks. So a helper
        // between its own start and `listener.resume()` - it files this keyboard's answer
        // in that window, then waits on the daemon - already reads as holding the service,
        // which is what the assistant's row needs it to say.
        return printed.stdout.contains("\"\(service)\" = {") ? .holdingTheService : .anotherJobHoldsTheService
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
        let deliveries: [Delivery] = delivery.map { [$0] } ?? Delivery.allCases
        let sources: [HotkeySource] = source.map { [$0] } ?? HotkeySource.allCases
        let needed = Requirement.Row.allCases.filter { $0.isNeeded(deliveries: deliveries, sources: sources) }
        // The helper's standing is read at most once and only if asked for, because two
        // rows want it: its own, and the assistant's, whose step depends on whether a
        // helper has run. The dependency is in the data rather than in the order the rows
        // happen to be read in. [LAW:no-ambient-temporal-coupling]
        lazy var helper = helperRow(flavor: flavor, approvalPending: reader.helperAwaitingApproval)
        var requirements: [Requirement] = []
        for row in needed where reader.canRead(row) {
            switch row {
            case .microphone:
                requirements.append(.privacy(.microphone, reader.privacy, flavor: flavor) { reading in
                    let withheld: MicrophoneAuthorization.Withheld? = switch reading.microphonePermission.current {
                    case .granted: nil
                    case .withheld(let reason): reason
                    }
                    return .microphone(withheld, flavor: flavor)
                })
            case .inputMonitoring:
                requirements.append(.privacy(.inputMonitoring, reader.privacy, flavor: flavor) {
                    .inputMonitoring(held: $0.inputMonitoring == .granted, flavor: flavor)
                })
            case .accessibility:
                requirements.append(.privacy(.accessibility, reader.privacy, flavor: flavor) {
                    .accessibility(held: $0.accessibility, flavor: flavor)
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
    private static func helperRow(flavor: Flavor, approvalPending: Bool?) -> (row: Requirement, aHelperHasRun: Bool) {
        do {
            let standing = try helperStanding(
                label: flavor.launchdLabel,
                service: flavor.machServiceName)
                .sharpenedByTheAppsOwnRegistration(approvalPending: approvalPending)
            return (.keyboardHelper(standing, flavor: flavor), standing.aHelperHasRun)
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

    public var description: String {
        switch self {
        case .launchdRefused(let label, let status, let complaint):
            "could not read what launchd holds for \(label): `launchctl print` exited \(status)\(complaint.isEmpty ? "" : ": \(complaint)")"
        case .plistUnreadable(let path, let reason):
            "could not read \(path): \(reason)"
        }
    }
}
