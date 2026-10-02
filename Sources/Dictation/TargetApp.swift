import AppKit
import LowTalkerCore

/// The app in front when a press begins: the app a session is about, before the input method
/// says which app's cursor actually took the words.
@MainActor
public enum TargetApp {
    /// [LAW:one-source-of-truth] Which app is in front is macOS's to say, so it is read here
    /// rather than remembered anywhere.
    public static func frontmost() throws -> BundleID {
        guard let app = NSWorkspace.shared.frontmostApplication else { throw FrontmostUnknown.noFrontmostApp }
        guard let id = app.bundleIdentifier else { throw FrontmostUnknown.withoutBundleID(pid: app.processIdentifier) }
        return BundleID(rawValue: id)
    }
}

public enum FrontmostUnknown: WordFree {
    case noFrontmostApp
    /// Something is in front that macOS gives no bundle id, so there is no name to aim at.
    case withoutBundleID(pid: pid_t)

    public var description: String {
        switch self {
        case .noFrontmostApp: "WARNING: No app is in front. Your dictation was ignored."
        case .withoutBundleID(let pid): "WARNING: The app in front (pid \(pid)) has no bundle id. Your dictation was ignored."
        }
    }
}
