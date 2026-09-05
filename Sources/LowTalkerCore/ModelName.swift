import Foundation

/// A model folder name in the whisperkit-coreml repo, such as `base.en` or
/// `large-v3-v20240930_626MB`. The repo grows, so this is a name, not an enum.
///
/// [LAW:parse-dont-validate] A name is one step of a path. Every path the store
/// builds from a name stays inside the store because a name that could climb out
/// cannot be made; the CLI refuses such a `--model` before any path exists.
public struct ModelName: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.isPathStep else { return nil }
        self.rawValue = rawValue
    }

    /// A literal is a name the author vouches for; one that is not a path step is a
    /// bug in the source, and traps where it is written.
    public init(stringLiteral value: String) {
        self.init(rawValue: value)!
    }

    public var description: String { rawValue }

    /// Whisper large-v3-turbo (large-v3's encoder with a four-layer decoder) in the
    /// variant that ships a prefilled decoder context. Chosen by `lowtalker bench`
    /// on an M2 Max: it heard every bench fixture exactly as the plain 626 MB
    /// variant did and decoded each one sooner, while the distilled models misheard
    /// proper nouns and the small models misheard whole phrases. The numbers are in
    /// the README under "The latency harness".
    public static let `default`: ModelName = "large-v3-v20240930_turbo_632MB"
}

extension StringProtocol {
    /// One step down a relative path: it names an entry, rather than standing still
    /// (`.`), climbing out (`..`), being nothing at all, or spanning several steps.
    var isPathStep: Bool {
        !isEmpty && self != "." && self != ".." && !contains("/")
    }
}
