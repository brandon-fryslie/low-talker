/// Modifier keys held together: the hotkey a user holds to speak. Never empty: every
/// constructor takes at least one modifier.
///
/// [LAW:types-are-the-program] Modifiers and nothing else, because the input method is told
/// only when a modifier key moves: a chord with any other key in it would never complete, so
/// it cannot be written down.
public struct KeyChord: Hashable, Codable, Sendable {
    public let modifiers: Set<Modifier>

    public init(modifiers first: Modifier, _ rest: Modifier...) {
        self.modifiers = Set(rest).union([first])
    }

    /// [LAW:parse-dont-validate] The one place a chord made of parts arrives unproven, a
    /// decoded one included; an empty one is nil here so no consumer has to check.
    /// [LAW:single-enforcer]
    public init?(modifiers: Set<Modifier>) {
        guard !modifiers.isEmpty else { return nil }
        self.modifiers = modifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let chord = KeyChord(modifiers: try container.decode(Set<Modifier>.self, forKey: .modifiers)) else {
            throw DecodingError.dataCorruptedError(forKey: .modifiers, in: container, debugDescription: "a chord needs at least one modifier")
        }
        self = chord
    }
}

/// Side-specific, because the hotkey distinguishes Right Option from Left Option.
public enum Modifier: String, Hashable, Codable, CaseIterable, Sendable, CustomStringConvertible {
    case leftShift, rightShift
    case leftControl, rightControl
    case leftOption, rightOption
    case leftCommand, rightCommand
    case function

    /// The spelling the file uses, so a report reads a chord back in the words its
    /// author typed rather than in Swift's name for the case.
    public var description: String { rawValue }

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
