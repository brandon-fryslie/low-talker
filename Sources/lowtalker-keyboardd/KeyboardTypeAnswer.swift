import DriverExtension
import Foundation

/// The answer Keyboard Setup Assistant would otherwise take the first typed line to ask
/// for, filed by the process that owns the keyboard.
///
/// macOS raises the assistant the moment a keyboard enumerates: it takes focus and asks
/// for the physical key beside left Shift, to decide ANSI/ISO/JIS. Measured during the
/// 3ti.2 spike, it swallowed the run's keystrokes outright - the text went to
/// `com.apple.KeyboardSetupAssistant` instead of the target app. The assistant files its
/// verdict under `<product>-<vendor>-<country>` and never asks again about a device that
/// already has one, so a device that files its own is never asked about.
///
/// [LAW:decomposition] This is the helper's, and not onboarding's, because of who can do
/// it rather than who noticed: the file is under /Library/Preferences and wants root,
/// this process is root, and it is the one process that must already be running before
/// the virtual keyboard can type at all. Onboarding used to print a `sudo defaults write`
/// for a reader to paste - a step that had no owner, not a step that needed a person.
enum KeyboardTypeAnswer {
    /// The cache with this keyboard's own answer in it, and every other device's left
    /// exactly as it was.
    ///
    /// [LAW:effects-at-boundaries] Pure, so the one thing this must never do - drop
    /// another device's entry - is asserted without root and without a file. The cache on
    /// this Mac already held an entry from an unrelated country-33 device, and the 3ti.7
    /// spike's other temptation was to initialise this keyboard as country 33 so it would
    /// collide with that entry: that would make the device declare something untrue about
    /// itself, and would work only until the unrelated entry was cleared. We write our
    /// own key and aim at nobody else's.
    static func filed(into cached: [String: Int]) -> [String: Int] {
        var answers = cached
        answers[VirtualKeyboardIdentity.keyboardTypeKey] = VirtualKeyboardIdentity.ansiKeyboardType
        return answers
    }

    /// Files it, reading what is there first so the merge has something to preserve.
    ///
    /// Unconditional: the same read, merge and write happen on every start, and the
    /// result is the same whether or not the entry was already there.
    /// [LAW:dataflow-not-control-flow] A start that skipped the write on the strength of
    /// a reading would be one more path to be wrong about, for a file written once a boot.
    static func file(into path: String = VirtualKeyboardIdentity.keyboardTypePlist) throws {
        let cache = try Cache.read(at: path)
        try cache.replacing(answers: filed(into: cache.answers)).write(to: path)
    }

    /// `/Library/Preferences/com.apple.keyboardtype` as this writer needs to see it: the
    /// answers, and whatever else the file holds, kept apart so the second is carried
    /// through untouched rather than re-derived. [LAW:types-are-the-program] A writer
    /// that modelled the file as its answers alone would write back a file missing every
    /// key it did not know about.
    struct Cache {
        /// Every top-level key, the answers included, as they were read.
        private let root: [String: Any]
        /// The answers under `keyboardtype`, by device key.
        let answers: [String: Int]

        private static let entry = "keyboardtype"

        /// What was in the file, or a refusal naming why it could not be read.
        ///
        /// [LAW:no-silent-failure] A file that is there and unreadable is never treated as
        /// a Mac with no answers yet: that reading would have this write back a file
        /// holding one entry where fourteen devices' answers used to be. Only a file that
        /// is genuinely absent, and a file holding no answers yet, are empty caches - and
        /// they are, because a Mac that has met no keyboard has nothing cached.
        static func read(at path: String) throws -> Cache {
            guard FileManager.default.fileExists(atPath: path) else { return Cache(root: [:], answers: [:]) }
            let contents: Any
            do {
                contents = try PropertyListSerialization.propertyList(
                    from: try Data(contentsOf: URL(fileURLWithPath: path)), options: [], format: nil)
            } catch {
                throw Unwritable.unreadable(path: path, reason: "\(error)")
            }
            guard let root = contents as? [String: Any] else {
                throw Unwritable.unreadable(path: path, reason: "its root is not a dictionary")
            }
            guard let cached = root[entry] else { return Cache(root: root, answers: [:]) }
            guard let answers = cached as? [String: Int] else {
                throw Unwritable.unreadable(path: path, reason: "its \(entry) entry is not a dictionary of numbers")
            }
            return Cache(root: root, answers: answers)
        }

        func replacing(answers: [String: Int]) -> Cache {
            var root = self.root
            root[Self.entry] = answers
            return Cache(root: root, answers: answers)
        }

        /// Written as the file rather than through `defaults`, because that is how the
        /// answers are read back: onboarding parses this same path with this same
        /// serializer, and a write that went through another door would be a second way
        /// for one fact to be stored. Measured on this Mac: a direct write to the file is
        /// what `defaults read` reports a moment later, in both directions, so cfprefsd
        /// serves this domain from the file rather than from a cache in front of it.
        func write(to path: String) throws {
            do {
                try PropertyListSerialization
                    .data(fromPropertyList: root, format: .binary, options: 0)
                    .write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                throw Unwritable.notWritten(path: path, reason: "\(error)")
            }
        }
    }

    /// Why this keyboard's answer could not be filed. Never swallowed into "filed": the
    /// consequence of believing it was is that the first dictation after an install types
    /// into a dialog, which is the whole reason this exists. [LAW:no-silent-failure]
    enum Unwritable: Error, CustomStringConvertible, Equatable {
        case unreadable(path: String, reason: String)
        case notWritten(path: String, reason: String)

        var description: String {
            switch self {
            case .unreadable(let path, let reason):
                "could not read \(path), so this keyboard's answer was not filed and nothing was overwritten: \(reason)"
            case .notWritten(let path, let reason):
                "could not write \(path): \(reason)"
            }
        }
    }
}
