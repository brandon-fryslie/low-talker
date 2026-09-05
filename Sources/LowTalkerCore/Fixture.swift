import Foundation

/// One utterance and what it says: a clip with its reference text, so an engine's
/// hearing of it can be scored. On disk a fixture is `<name>.wav` beside
/// `<name>.txt`.
///
/// [LAW:parse-dont-validate] The checkpoint for scoring: a fixture in hand has a
/// reference with at least one word, so every rate computed over it is a number.
public struct Fixture: Sendable {
    public let name: String
    public let clip: AudioClip
    public let reference: SpokenWords

    public init(name: String, clip: AudioClip, reference text: String) throws {
        let reference = SpokenWords(text)
        guard !reference.words.isEmpty else { throw FixtureError.referenceSaysNothing(name: name) }
        self.name = name
        self.clip = clip
        self.reference = reference
    }

    /// Every fixture under a directory, by name, where the name is the path from
    /// the directory to the pair with the extension removed, so `say/greeting` and
    /// `librispeech/2277-149896-0000` say where each came from. A wav without its
    /// text is refused: a clip nobody wrote down cannot be scored, and skipping it
    /// would quietly shrink the set. Text without a wav is refused for the same reason.
    ///
    /// [LAW:no-silent-failure] A directory with no fixtures is an error, not an
    /// empty report, and a folder the walk cannot list stops it.
    public static func load(directory: URL) throws -> [Fixture] {
        let root = directory.standardizedFileURL.path
        var failure: FixtureError?
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) { url, error in
            failure = .unreadable(url, reason: "\(error)")
            return false
        }
        guard let enumerator else { throw FixtureError.unreadable(directory, reason: "no enumerator") }
        // The extension is read once, case-folded, so `foo.WAV` pairs like `foo.wav`
        // and the guarantee above holds on any filesystem.
        let entries = enumerator.compactMap { $0 as? URL }
            .map { (kind: $0.pathExtension.lowercased(), url: $0) }
            .filter { ["wav", "txt"].contains($0.kind) }
        if let failure { throw failure }
        let stems = Dictionary(grouping: entries) { String($0.url.standardizedFileURL.deletingPathExtension().path.dropFirst(root.count + 1)) }
        guard !stems.isEmpty else { throw FixtureError.noFixtures(directory: directory) }
        return try stems.keys.sorted().map { name in
            // [LAW:no-silent-failure] Two spellings of one slot throw rather than
            // letting the walk's order pick one.
            let files = try Dictionary(stems[name]!.map { ($0.kind, $0.url) }) { first, second in
                throw FixtureError.twoOfAKind(name: name, first: first, second: second)
            }
            guard let wav = files["wav"], let txt = files["txt"] else {
                throw FixtureError.halfAFixture(name: name, directory: directory, missing: files["wav"] == nil ? "wav" : "txt")
            }
            let clip = try AudioClip(contentsOf: wav)
            let text = try String(contentsOf: txt, encoding: .utf8)
            return try Fixture(name: name, clip: clip, reference: text)
        }
    }
}

public enum FixtureError: Error, Equatable, CustomStringConvertible {
    /// The walk over the directory did not finish; `URL` is where it stopped.
    case unreadable(URL, reason: String)
    case noFixtures(directory: URL)
    /// A `.wav` or `.txt` whose partner is not beside it.
    case halfAFixture(name: String, directory: URL, missing: String)
    /// Two files for one slot, such as `foo.wav` beside `foo.WAV` on a case-sensitive volume.
    case twoOfAKind(name: String, first: URL, second: URL)
    /// The reference text has no words to score against.
    case referenceSaysNothing(name: String)

    public var description: String {
        switch self {
        case .unreadable(let url, let reason):
            "cannot list \(url.path): \(reason)"
        case .noFixtures(let directory):
            "no fixtures under \(directory.path): expected <name>.wav beside <name>.txt"
        case .halfAFixture(let name, let directory, let missing):
            "fixture \(name) under \(directory.path) has no \(name).\(missing)"
        case .twoOfAKind(let name, let first, let second):
            "fixture \(name) has two files for one slot: \(first.lastPathComponent) and \(second.lastPathComponent)"
        case .referenceSaysNothing(let name):
            "fixture \(name)'s reference text has no words"
        }
    }
}
