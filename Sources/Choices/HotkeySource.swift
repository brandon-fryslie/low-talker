/// How the hotkey is heard. Independent of how the words are delivered - any hearing goes
/// with any `Delivery`, and neither one decides the other.
///
/// What differs between the two is what macOS asks for and what it allows in return: an
/// event tap sees every key, so its chord can be modifiers alone, and it needs Input
/// Monitoring and Accessibility; a registered hot key needs nothing, and macOS will only
/// register a chord that has a key in it. Which grants each needs is Onboarding's list to
/// say, as `Requirement.Row.grants(for:)`, and every surface that names them reads it there.
///
/// [LAW:locality-or-seam] Everything a reader of a hearing needs to know about it is a
/// value read off it here, so a new hearing is a new case in this file, its chord and tap
/// in LowTalkerCore's `Hotkey` and its grants in Onboarding's list, and no reader
/// elsewhere switches on which one it holds.
public enum HotkeySource: String, CaseIterable, Sendable, CustomStringConvertible {
    /// An active event tap on the session's keyboard events. Needs Input Monitoring to
    /// read the keys and Accessibility to hold the chord back from the app in front.
    case eventTap
    /// A hot key registered with the window server. Needs no permission.
    case registeredHotKey

    /// The spelling a stored choice is kept under, which is the case name.
    public var description: String { rawValue }

    /// Whether this hearing tells a left modifier from a right one. An event tap reads the
    /// device-side flag bits; Carbon matches Control, Option, Shift and Command whichever
    /// side is down, so a chord it hears is named without sides.
    public var hearsSides: Bool {
        switch self {
        case .eventTap: true
        case .registeredHotKey: false
        }
    }
}
