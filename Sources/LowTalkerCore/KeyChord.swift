/// Keys pressed together: the hotkey a user holds to speak, or the keystroke a
/// SendKeys action posts. Never empty: every constructor takes at least one key.
///
/// [LAW:one-type-per-behavior] Both are the same thing to the OS, so they are the same
/// type here; a chord read off the event tap can be replayed by SendKeys unchanged.
public struct KeyChord: Hashable, Codable, Sendable {
    public let modifiers: Set<Modifier>
    /// The non-modifier key, if the chord has one. A push-to-talk hotkey such as Right
    /// Option is modifiers only.
    public let key: Key?

    public init(key: Key, modifiers: Set<Modifier> = []) {
        self.modifiers = modifiers
        self.key = key
    }

    public init(modifiers first: Modifier, _ rest: Modifier...) {
        self.modifiers = Set(rest).union([first])
        self.key = nil
    }

    /// [LAW:parse-dont-validate] The one place a chord arrives unproven; an empty one is
    /// refused here so no consumer has to check.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let modifiers = try container.decode(Set<Modifier>.self, forKey: .modifiers)
        let key = try container.decodeIfPresent(Key.self, forKey: .key)
        guard key != nil || !modifiers.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .modifiers, in: container, debugDescription: "a chord needs at least one key")
        }
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

    /// [LAW:single-enforcer] Which modifiers exist is this type's rule, so a file that
    /// names another is answered from the cases themselves and never falls out of step
    /// with them.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let modifier = Modifier(rawValue: raw) else {
            throw decoder.fault("\"\(raw)\" is not a modifier: \(Modifier.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        self = modifier
    }
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
