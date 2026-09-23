/// How the hotkey is heard. Independent of how the words are delivered - any hearing goes
/// with any `Delivery`, and neither one decides the other.
///
/// What differs between the two is what macOS asks for and what it allows in return: an
/// event tap sees every key, so its chord can be modifiers alone, and it needs Input
/// Monitoring; a registered hot key needs nothing, and macOS will only register a chord
/// that has a key in it.
public enum HotkeySource: String, CaseIterable, Sendable, CustomStringConvertible {
    /// An event tap on the session's keyboard events. Needs Input Monitoring.
    case eventTap
    /// A hot key registered with the window server. Needs no permission.
    case registeredHotKey

    /// The spelling a stored choice is kept under, which is the case name.
    public var description: String { rawValue }
}
