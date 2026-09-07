import Foundation

/// The settings the app runs on: the model the engine loads, and the modes a chord can
/// start. Nothing here is read from disk; `Config(toml:)` is where a file becomes one.
///
/// [LAW:parse-dont-validate] A Config in hand is one that holds together: it has at
/// least one mode, no two modes answer to the same chord, and no two share a name or
/// go without one. The initializer is the only way to make a Config, so those facts
/// are established once here and never asked again downstream - which is why
/// `mode(for:)` can speak of *the* mode a chord selects.
public struct Config: Hashable, Sendable {
    public let model: ModelName
    /// In the order the file declared them, because that is the order `lowtalker
    /// config check` and any listing should speak of them in.
    public let modes: [Mode]

    public init(model: ModelName, modes: [Mode]) throws(ConfigError) {
        guard !modes.isEmpty else { throw ConfigError.noModes }
        var names: Set<String> = []
        var chords: Set<KeyChord> = []
        for mode in modes {
            guard !mode.name.isEmpty else { throw ConfigError.modeUnnamed }
            guard names.insert(mode.name).inserted else { throw ConfigError.twoModesNamed(mode.name) }
            guard chords.insert(mode.chord).inserted else { throw ConfigError.twoModesOnOneChord(mode.name) }
        }
        self.model = model
        self.modes = modes
    }

    /// What the app runs on when no file says otherwise: dictation, on the default
    /// chord, with the default model.
    ///
    /// [LAW:one-source-of-truth] Every part of it is the value its own owner already
    /// names, so the no-file behaviour cannot drift from the behaviour those owners
    /// describe. The force-try says the author vouches for this one: a default that
    /// does not hold together is a bug in this file, and it traps where it is written.
    public static let `default` = try! Config(model: .default, modes: [.dictation])

    /// The mode the chord that started listening selects, or none when no mode claims
    /// it. `chords` is what the tap is told to listen for, so in a running app a
    /// Context always names one; a Context assembled by hand need not.
    public func mode(for chord: KeyChord) -> Mode? {
        modes.first { $0.chord == chord }
    }

    /// What the hotkey listens for. One chord per mode, and never empty.
    public var chords: Set<KeyChord> {
        Set(modes.map(\.chord))
    }
}

/// One way of speaking: the chord that starts it, what the engine is told to expect
/// before any words arrive, and the routes that turn what was said into actions.
///
/// [LAW:one-type-per-behavior] Dictation is not a case in code. It is a Mode like
/// every other, the one `Config.default` supplies when no file names any.
public struct Mode: Hashable, Sendable {
    /// How the mode is spoken of in errors and in `lowtalker config check`.
    public let name: String
    /// The chord that selects this mode. `Context.chord` carries it, so which mode is
    /// running is settled before a word is heard.
    public let chord: KeyChord
    /// What the engine is told to expect, so a name it could not have guessed is
    /// spelled the way this mode wants it.
    public let vocabulary: Vocabulary
    public let router: Router

    /// The name arrives trimmed, as a Vocabulary term does, so that two modes cannot
    /// differ by spacing alone.
    public init(name: String, chord: KeyChord, vocabulary: Vocabulary = .empty, router: Router) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.chord = chord
        self.vocabulary = vocabulary
        self.router = router
    }

    /// Hold the hotkey, speak, and the words are typed wherever the focus is.
    public static let dictation = Mode(
        name: "dictation",
        chord: Hotkey.defaultChord,
        vocabulary: .empty,
        router: Router(routes: [.dictation])
    )
}

/// What is wrong with a config, in the words a person editing the file needs.
///
/// [LAW:no-silent-failure] Every case here is a file that was written but not
/// understood. None of them is answered with the defaults: "there is no config" and
/// "there is a config I could not read" are different facts, and collapsing them
/// would run the app on settings its owner never chose.
public enum ConfigError: Error, Equatable, CustomStringConvertible {
    /// The file is not TOML at all, at the line where reading it stopped.
    case notTOML(String, line: Int)
    /// A key the schema has no place for, named with where it sits so the typo can be
    /// found.
    case unknownKeys([String])
    /// The file is TOML, but something in it was refused: where, and why, in the words
    /// of whichever decoder did the refusing.
    case wrongShape(String)
    case noModes
    case modeUnnamed
    case twoModesNamed(String)
    case twoModesOnOneChord(String)
    /// The file exists but could not be read at all, in the words the system used.
    case unreadable(path: String, why: String)
    /// A refusal the parser reported that this file has no better words for. Carried
    /// rather than dropped: a fault nobody named is worse than one named awkwardly.
    case notUnderstood(String)

    public var description: String {
        switch self {
        case .notTOML(let why, let line):
            "line \(line) is not TOML: \(why)"
        case .unknownKeys(let keys):
            "nothing in a config is called \(keys.map { "\"\($0)\"" }.joined(separator: ", "))"
        case .wrongShape(let why):
            why
        case .noModes:
            "the config declares no modes, so no chord would start listening"
        case .modeUnnamed:
            "a mode has no name"
        case .twoModesNamed(let name):
            "two modes are named \"\(name)\""
        case .twoModesOnOneChord(let name):
            "mode \"\(name)\" answers to a chord another mode already answers to"
        case .unreadable(let path, let why):
            "\(path) could not be read: \(why)"
        case .notUnderstood(let why):
            why
        }
    }
}
