import Foundation

/// The closed set of things low-talker can do. A route produces these; an executor at
/// the app's edge performs them.
///
/// [LAW:effects-at-boundaries] An Action is a description, not a call. The router and
/// every route stay pure and testable, and a Pipe program can hand actions back as
/// JSON because they are only data.
///
/// Every payload is labeled so the synthesized Codable form is the readable wire
/// contract Pipe programs write, e.g. `{"activateApp":{"bundleID":"com.apple.Safari"}}`.
public enum Action: Hashable, Codable, Sendable {
    case insertText(text: String, target: InsertTarget)
    case sendKeys(chord: KeyChord)
    case activateApp(bundleID: BundleID)
    case openURL(url: URL)
    /// A Shortcuts.app shortcut by name, optionally handed input text.
    case runShortcut(name: String, input: String?)
    /// Hands the transcript to an external program and reads a list of actions back as
    /// JSON. `executable` is separate from `arguments` so an empty command line is
    /// unrepresentable.
    case pipe(executable: String, arguments: [String])
}

/// Where inserted text goes: the focused element, or a named app regardless of focus.
public enum InsertTarget: Hashable, Codable, Sendable {
    case focus
    case app(bundleID: BundleID)
}
