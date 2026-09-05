/// Everything known before the user spoke. The router reads it; nothing writes it
/// after the hotkey goes down.
public struct Context: Hashable, Codable, Sendable {
    /// The chord that started listening. It selects the mode; the transcript never does.
    public let chord: KeyChord
    public let press: PressKind
    public let frontmostApp: BundleID
    /// The Accessibility role of the focused element, or nil when nothing has focus or
    /// the frontmost app exposes no accessibility tree.
    public let focusedElementRole: AccessibilityRole?

    public init(chord: KeyChord, press: PressKind, frontmostApp: BundleID, focusedElementRole: AccessibilityRole?) {
        self.chord = chord
        self.press = press
        self.frontmostApp = frontmostApp
        self.focusedElementRole = focusedElementRole
    }
}

/// A short press toggles listening; a long one is push-to-talk. The threshold belongs
/// to the event tap, which resolves it before a Context exists.
public enum PressKind: String, Hashable, Codable, Sendable {
    case tap, hold
}

/// An Accessibility API role string such as `AXTextField`. Apps may define their own
/// roles, so this is an open set, not an enum.
public struct AccessibilityRole: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
