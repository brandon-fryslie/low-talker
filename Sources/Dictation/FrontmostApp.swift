import AppKit
import LowTalkerCore

/// The app in front, by name, read at key-down so the Context can say where the
/// words go.
///
/// [LAW:parse-dont-validate] The one place the window server's answer becomes a
/// BundleID. Nothing in front, or an app with no bundle identifier (a bare executable
/// that opened a window), is refused here by name, and everything after key-down
/// holds an app the typist can prove in front before every key.
public enum FrontmostApp {
    @MainActor
    public static func read() throws -> BundleID {
        guard let app = NSWorkspace.shared.frontmostApplication else { throw NothingToTypeInto.noFrontmostApp }
        guard let name = app.bundleIdentifier else { throw NothingToTypeInto.unnamedApp(pid: app.processIdentifier) }
        return BundleID(rawValue: name)
    }
}

public enum NothingToTypeInto: Error, CustomStringConvertible {
    case noFrontmostApp
    case unnamedApp(pid: pid_t)

    public var description: String {
        switch self {
        case .noFrontmostApp: "no app is in front, so there is nothing to type into"
        case .unnamedApp(let pid): "the app in front (pid \(pid)) has no bundle identifier, so the typist cannot name it"
        }
    }
}
