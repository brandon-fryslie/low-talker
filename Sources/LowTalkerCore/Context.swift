/// Everything known before the user spoke, as the session reports it; nothing writes it
/// after the hotkey goes down.
public struct Context: Hashable, Sendable {
    /// The chord that started listening. It selects the mode; the transcript never does.
    public let chord: KeyChord
    public let press: PressKind
    public let frontmostApp: BundleID

    public init(chord: KeyChord, press: PressKind, frontmostApp: BundleID) {
        self.chord = chord
        self.press = press
        self.frontmostApp = frontmostApp
    }
}

/// A short press toggles listening; a long one is push-to-talk. The threshold belongs
/// to the hotkey, which resolves it before a Context exists.
public enum PressKind: String, Hashable, Sendable {
    case tap, hold
}
