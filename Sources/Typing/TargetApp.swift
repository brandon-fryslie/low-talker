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

public enum FrontmostUnknown: Error, CustomStringConvertible {
    case noFrontmostApp
    /// Something is in front that macOS gives no bundle id, so there is no name to aim at.
    case withoutBundleID(pid: pid_t)

    public var description: String {
        switch self {
        case .noFrontmostApp: "no app is frontmost, so there is nowhere for the words to go"
        case .withoutBundleID(let pid): "the app in front (pid \(pid)) has no bundle id, so there is no name to aim at"
        }
    }
}
