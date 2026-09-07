import Foundation
import TOMLKit

public extension Config {
    /// The one file, at the one path.
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/low-talker/config.toml")
    }

    /// [LAW:parse-dont-validate] The one place config text becomes a Config. What comes
    /// back holds together or this throws naming what does not, so nothing downstream
    /// examines the file again: there is no text left to examine.
    ///
    /// [LAW:effects-at-boundaries] Pure. It opens nothing and reads no clock, so a test
    /// hands it a string rather than a filesystem.
    init(toml: String) throws {
        var decoder = TOMLDecoder()
        // A key this schema has no place for is a typo the author wants told, not a
        // line quietly doing nothing. [LAW:no-silent-failure]
        decoder.strictDecoding = true
        let file: ConfigFile
        do {
            file = try decoder.decode(ConfigFile.self, from: toml)
        } catch let error as TOMLParseError {
            throw ConfigError.notTOML(error.description, line: error.source.begin.line)
        } catch let error as UnexpectedKeysError {
            // Sorted here rather than where they are printed, so two runs over one bad
            // file name the same keys in the same order. [LAW:one-source-of-truth]
            throw ConfigError.unknownKeys(error.keys.keys.sorted())
        } catch let error as DecodingError {
            throw ConfigError.wrongShape(error.sentence)
        }
        // [LAW:one-source-of-truth] A key the file leaves out falls back to the value in
        // Config.default, which is where the no-file behaviour is written; no default is
        // spelled a second time here to drift from it.
        try self.init(
            model: file.model ?? Config.default.model,
            modes: file.modes?.map { try $0.mode() } ?? Config.default.modes
        )
    }

    /// The config the app runs on: what the file says, or the defaults when there is no
    /// file.
    ///
    /// [LAW:no-silent-failure] Only a file that is not there yields the defaults. One
    /// that exists and cannot be read, or cannot be understood, throws - so a config the
    /// user wrote is never quietly replaced by one they did not.
    static func load(from url: URL = fileURL) throws -> Config {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .default
        }
        return try Config(toml: text)
    }
}

/// The file's shape, which is not the app's. It exists so the spelling in the file can
/// be the one a person would write, while `Config` stays the shape the app runs on;
/// mapping between them is what parsing this file means.
private struct ConfigFile: Decodable {
    let model: ModelName?
    let modes: [ModeEntry]?
}

/// One `[[modes]]` table.
private struct ModeEntry: Decodable {
    let name: String
    let chord: KeyChord
    let vocabulary: [String]?
    let routes: [RouteEntry]?

    /// [LAW:single-enforcer] The chord arrived through KeyChord's own decoder and each
    /// term goes through Vocabulary.Term, so what a chord and a term may be is settled
    /// where those types live and is not restated here.
    func mode() throws -> Mode {
        Mode(
            name: name,
            chord: chord,
            vocabulary: Vocabulary(try (vocabulary ?? []).map(Vocabulary.Term.init)),
            // A mode that names no routes dictates, which is the only thing it could
            // have meant; one that names an empty list claims nothing, and `lowtalker
            // config check` is where that gap is reported.
            router: routes.map { Router(routes: $0.map(\.route)) } ?? Router(routes: [.dictation])
        )
    }
}

/// One `[[modes.routes]]` table: what claims an utterance, and what becomes of it.
private struct RouteEntry: Decodable {
    let when: MatchEntry
    let then: EmitEntry

    var route: Route { Route(when: when.match, then: then.emit) }
}

/// `when = "always"`. A word, because a match that carries nothing is a word; a match
/// that carries something becomes a table, the way `then` already is one.
private struct MatchEntry: Decodable {
    let match: Route.Match

    init(from decoder: any Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        switch name {
        case "always": match = .always
        default: throw ConfigError.noSuchMatch(name)
        }
    }
}

/// `then = { insert = "focus" }`: a table naming exactly one thing to do, so a route can
/// neither ask for two at once nor for none.
private struct EmitEntry: Decodable {
    let emit: Route.Emit

    private enum CodingKeys: String, CodingKey { case insert }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1 else { throw ConfigError.thenNamesNoOneThing }
        emit = .insertTranscript(target: try container.decode(TargetEntry.self, forKey: .insert).target)
    }
}

/// `insert = "focus"`, or `insert = { app = "com.slack.Slack" }`: the word when the
/// target carries nothing, the table when it carries a bundle id.
private struct TargetEntry: Decodable {
    let target: InsertTarget

    private enum CodingKeys: String, CodingKey { case app }

    init(from decoder: any Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            guard name == "focus" else { throw ConfigError.noSuchTarget(name) }
            target = .focus
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            target = .app(bundleID: try container.decode(BundleID.self, forKey: .app))
        }
    }
}

private extension DecodingError {
    /// The same fault in the words the file's author needs: which key, and what is wrong
    /// with it. The type names Swift puts in these errors describe the parser's own
    /// types, which mean nothing to someone editing TOML.
    var sentence: String {
        switch self {
        case .keyNotFound(let key, let context):
            "\(Self.path(context.codingPath + [key])) is missing"
        case .typeMismatch(_, let context):
            "\(Self.path(context.codingPath)) is not the kind of value that key takes"
        case .valueNotFound(_, let context):
            "\(Self.path(context.codingPath)) has no value"
        // The one case a hand-written decoder puts its own reason in, such as KeyChord
        // refusing a chord with nothing in it. That sentence is better than any this
        // file could invent, so it is carried through rather than replaced.
        case .dataCorrupted(let context):
            "\(Self.path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            "the config could not be read"
        }
    }

    static func path(_ keys: [any CodingKey]) -> String {
        keys.isEmpty ? "the config" : keys.map(\.stringValue).joined(separator: ".")
    }
}
