// The words for where an input source stands, apart from the Text Input Sources calls that
// read it, so a reader of the words - onboarding, and through it the CLI - links no window
// server. [LAW:one-way-deps]

/// Where this flavor's input source stands on this Mac, as the text input system reports it.
///
/// A ladder and not a set of flags: each rung is the one below it plus one more thing that
/// has happened, and `install` walks it from wherever this Mac is standing.
/// [LAW:types-are-the-program] Nothing here is remembered between launches - every reading
/// is taken from the text input system and the file system now, so a bundle the user
/// deleted by hand reads as gone at the next look rather than as whatever the last install
/// recorded. [FRAMING:representation]
public enum InputSourceState: Equatable, Sendable, CaseIterable, CustomStringConvertible {
    /// Nothing stands at this flavor's place in `~/Library/Input Methods`.
    case bundleNotInstalled
    /// The bundle is there and the text input system holds no source for it, which is the
    /// state a bundle copied in by hand sits in until something registers it.
    case notRegistered
    /// Registered, and switched off: it is not in the Input menu and cannot be selected.
    ///
    /// Where a first install stops until the next login. Measured on 2026-09-24
    /// (low-input-method-s71.ssn): an input method first registered during a login session
    /// cannot be switched on until the next one - `TISEnableInputSource` answers `noErr` and
    /// changes nothing, with the bundle versioned and Developer ID signed, whatever is
    /// written to the enabled-sources preference or restarted.
    case disabled
    /// In the Input menu, and some other source is the one in use.
    case enabled
    /// The source in use, which is the only state an insert can happen from.
    ///
    /// Kept selected for as long as the delivery is the input method, rather than selected
    /// for each press and put back after it. Measured on 2026-09-22: a source selected from
    /// this background app becomes current at once, but the app in front goes on talking to
    /// the input method it had until its own focus changes - so a press-length selection is
    /// an input method with no client for the length of the press, and every insert refused.
    /// Selected once, the source is what every app picks up as it takes focus. The input
    /// method's controller passes every key through, so typing is unchanged by it.
    case selected

    /// Whether the input method can be asked to insert.
    public var ready: Bool { self == .selected }

    public var description: String {
        switch self {
        case .bundleNotInstalled: "not installed"
        case .notRegistered: "installed, not registered"
        case .disabled: "registered, switched off"
        case .enabled: "enabled, not selected"
        case .selected: "selected"
        }
    }
}
