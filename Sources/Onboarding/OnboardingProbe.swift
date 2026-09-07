import DriverExtension
import Foundation

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
    public static func helperStanding(label: String, service: String) throws -> HelperStanding {
        let printed = try Command("/bin/launchctl", "print", "system/\(label)").run()
        return try standing(from: printed, label: label, service: service)
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
        return printed.stdout.contains("\"\(service)\" = {") ? .holdingTheService : .anotherJobHoldsTheService
    }

    /// Whether Keyboard Setup Assistant already holds a verdict for this keyboard.
    ///
    /// The file is world-readable, so this needs no privilege; writing the entry does,
    /// which is why the requirement names a command rather than taking the step itself.
    public static func keyboardSetupAssistantAnswered(
        key: String = VirtualKeyboardIdentity.keyboardTypeKey,
        at path: String = keyboardTypePlist
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

    /// Where macOS files the assistant's answers, as `defaults` names it. The
    /// requirement prints this inside the command that writes it, and a step naming a
    /// different file from the one that was read is a step that does nothing - so the
    /// file below is derived from it rather than written out a second time.
    /// [LAW:one-source-of-truth]
    public static let keyboardTypeDomain = "/Library/Preferences/com.apple.keyboardtype"

    /// The same thing as a file. `defaults` takes the domain and
    /// `PropertyListSerialization` takes the file, and they are one path.
    public static let keyboardTypePlist = keyboardTypeDomain + ".plist"
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
