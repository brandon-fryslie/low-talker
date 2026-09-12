import DriverExtension
import Flavors
import Foundation
import KeyboardService

/// Reading this Mac for the two facts onboarding takes for itself: which launchd job
/// holds the helper's Mach service, and whether Keyboard Setup Assistant already has an
/// answer for the virtual keyboard.
///
/// [LAW:effects-at-boundaries] Both are effects, and both are separated from the pure
/// mapping that turns them into a `Requirement`, so the steps can be asserted as values
/// on a Mac that is in none of the states worth checking.
public enum OnboardingProbe {
    /// Where the helper stands, as launchd sees it.
    ///
    /// Read without root on purpose: the menu-bar app is not root and this is its
    /// question. `launchctl print` is a debug dump rather than an interface, and its
    /// shape is already what `scripts/keyboard-helper install` reads back to find out
    /// whether its own job got the name; both now ask through here.
    /// [LAW:one-source-of-truth]
    /// Where this flavor's helper stands, asked of the one label that can hold it.
    ///
    /// One question and no second reading, because there is no second label to ask about.
    /// A flavor's launchd job and its Mach service carry one name, so a rival job cannot
    /// exist: `launchctl bootstrap` refuses a duplicate label outright (exit 5, measured),
    /// where it used to accept a second label naming the same service and hand it no
    /// endpoint. What remains unaccounted for is a helper running outside launchd
    /// entirely, and that one is reported as what it is - a holder that can be found but
    /// not named. [LAW:no-silent-failure]
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

public extension OnboardingProbe {
    /// Everything that must hold before low-talker can type, read off this Mac now.
    ///
    /// The list is assembled here and nowhere else. `lowtalker onboard` and the menu-bar
    /// app are two views of one list rather than two lists that happen to agree, and a
    /// surface that built its own would drift the first time a requirement was added to
    /// only one of them - which is exactly what low-hotkey-a6m.2 is about to do.
    /// [LAW:one-source-of-truth]
    ///
    /// - Parameter flavor: which installation is being read. The two run side by side and
    ///   each has its own helper, service and label, so every reading below is a reading
    ///   about one of them and there is no such thing as the readiness of "the app".
    /// - Parameter approvalPending: what `SMAppService` told the app that owns the
    ///   helper's registration, and nil from a caller that owns none. See
    ///   `HelperStanding.sharpenedByTheAppsOwnRegistration(approvalPending:)`.
    static func readiness(flavor: Flavor, approvalPending: Bool?) -> Readiness {
        // The helper's row is read before the assistant's because the assistant's step
        // depends on it: the answer is filed BY the helper, so what is left to do about a
        // missing answer is a different thing depending on whether the helper has run.
        // The dependency is in the data rather than in the order two independent readings
        // happen to be taken in. [LAW:no-ambient-temporal-coupling]
        let helper = helperRow(flavor: flavor, approvalPending: approvalPending)
        return Readiness(driverRow() + helper.rows + keyboardSetupAssistantRow(flavor: flavor, aHelperHasRun: helper.aHelperHasRun))
    }

    /// Each reading is taken and turned into its row here, at the edge, and a reading
    /// that failed becomes a row saying so rather than ending the report: three
    /// requirements a reader could have acted on are worth more than one error.
    /// [LAW:effects-at-boundaries]
    private static func driverRow() -> [Requirement] {
        do { return [.driverExtension(DriverState(try DriverProbe.facts()))] }
        catch { return [.unreadable(.driverExtension, error)] }
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
    private static func helperRow(flavor: Flavor, approvalPending: Bool?) -> (rows: [Requirement], aHelperHasRun: Bool) {
        do {
            let standing = try helperStanding(
                label: flavor.launchdLabel,
                service: flavor.machServiceName)
                .sharpenedByTheAppsOwnRegistration(approvalPending: approvalPending)
            return ([.keyboardHelper(standing, serviceName: flavor.machServiceName)],
                    standing.aHelperHasRun)
        } catch { return ([.unreadable(.keyboardHelper, error)], false) }
    }

    private static func keyboardSetupAssistantRow(flavor: Flavor, aHelperHasRun: Bool) -> [Requirement] {
        do {
            return [.keyboardSetupAssistant(
                answered: try keyboardSetupAssistantAnswered(),
                aHelperHasRun: aHelperHasRun,
                helperSubsystem: flavor.machServiceName)]
        } catch { return [.unreadable(.keyboardSetupAssistant, error)] }
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
