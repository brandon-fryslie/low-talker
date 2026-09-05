/// Keys pressed together: the hotkey a user holds to speak, or the keystroke a
/// SendKeys action posts.
///
/// [LAW:one-type-per-behavior] Both are the same thing to the OS, so they are the same
/// type here; a chord read off the event tap can be replayed by SendKeys unchanged.
public struct KeyChord: Hashable, Codable, Sendable {
    public var modifiers: Set<Modifier>
    /// The non-modifier key, if the chord has one. A push-to-talk hotkey such as Right
    /// Option is modifiers only.
    public var key: Key?

    public init(modifiers: Set<Modifier>, key: Key? = nil) {
        self.modifiers = modifiers
        self.key = key
    }
}

/// Side-specific, because the hotkey distinguishes Right Option from Left Option.
public enum Modifier: String, Hashable, Codable, CaseIterable, Sendable {
    case leftShift, rightShift
    case leftControl, rightControl
    case leftOption, rightOption
    case leftCommand, rightCommand
    case function
}

/// A macOS virtual key code (the `kVK_*` constants; `CGKeyCode`). Key codes rather
/// than characters because posting an event needs the code, and the code is the same
/// under every keyboard layout.
public struct Key: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }
}
