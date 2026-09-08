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
    /// [LAW:effects-at-boundaries] Pure, so the one thing the merge must never do - drop
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
    /// The write is the merge's result, so a merge that changed nothing writes nothing -
    /// which is not a skipped operation but an empty one, the way filtering to nothing
    /// returns an empty list. [LAW:dataflow-not-control-flow] It matters because every
    /// rewrite is another chance to lose a race: this is a read-modify-write of a file
    /// shared with Keyboard Setup Assistant itself, and a writer landing between the read
    /// and the write has its entry overwritten by the snapshot this took. Writing only
    /// what changes leaves that window on the one start that has something to file and on
    /// no start after it.
    ///
    /// What survives every other device's answer is the merge, and only the merge. A
    /// writer outside this process, inside that window, can still lose one, and nothing
    /// available here prevents it: a lock serializes only writers that take it, and
    /// Keyboard Setup Assistant and cfprefsd take none. Said plainly rather than dressed
    /// as a guarantee this cannot keep.
    @discardableResult
    static func file(into path: String = VirtualKeyboardIdentity.keyboardTypePlist) throws(Unwritable) -> Filing {
        let cache = try Cache.read(at: path)
        let answers = filed(into: cache.answers)
        let filing: Filing = answers == cache.answers ? .alreadyFiled : .filed
        if filing == .filed {
            try cache.replacing(answers: answers).write(to: path)
        }
        // Every start, and not only the one that wrote. The content and the mode are two
        // different facts about this file with two different conditions, and one guard
        // over both is what made the mode repairable on the first boot and never again:
        // a file left 0600 by an interrupted first start, or tightened later by anything
        // outside this process, was read on every subsequent start, found to need no
        // merge, and returned from before the mode was ever looked at - so onboarding's
        // unprivileged read failed permanently while the helper believed itself fine.
        // [LAW:dataflow-not-control-flow]
        try Cache.makeReadable(at: path)
        return filing
    }

    /// What a start found. Two named outcomes rather than a bare Bool, because the log
    /// line differs and "already there" is the ordinary case on every boot after the
    /// first - a start that says nothing about which one it was leaves a reader unable to
    /// tell a working helper from one that has stopped filing anything.
    ///
    /// Which is a claim about the log, so it is kept where the log can be held to it: the
    /// cases carry the words the helper says, and a test reads them back to check that no
    /// two outcomes reach a reader as the same sentence. The enum existed for one start
    /// before the caller discarded it and logged one line either way - the justification
    /// above true of the type and false of the program. [LAW:one-source-of-truth]
    /// `CaseIterable` so that check covers an outcome added later without being asked to.
    enum Filing: Equatable, CaseIterable, CustomStringConvertible {
        case alreadyFiled
        case filed

        public var description: String {
            switch self {
            case .filed: "is now filed"
            case .alreadyFiled: "was already filed"
            }
        }
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
        static func read(at path: String) throws(Unwritable) -> Cache {
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

        /// The mode the file must end up with, whoever wrote it.
        ///
        /// World-readable is load-bearing rather than incidental: onboarding reads this
        /// file with no privilege, and a file this helper tightened would leave that row
        /// permanently unreadable for every ordinary user while the answer inside it was
        /// perfectly correct. Measured on this platform: an atomic *replace* keeps the
        /// existing file's mode, so a Mac that already has this file is never tightened -
        /// but an atomic *create* takes the writer's umask, and a Mac that has met no
        /// keyboard has no file for this to replace. launchd's umask is settable per job,
        /// so left alone the permissions of the file this creates would be a fact about
        /// the job's configuration rather than about this writer. Set, they are neither.
        private static let mode: NSNumber = 0o644

        /// Makes it so, on a file that is already there.
        ///
        /// The one place the mode is set, so there is one answer to what it should be
        /// rather than one per path through the filing. [LAW:single-enforcer] Asserted
        /// rather than checked-then-set: the call costs the same either way, and a read
        /// followed by a conditional write is a window for the two to disagree.
        static func makeReadable(at path: String) throws(Unwritable) {
            do {
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
            } catch {
                throw Unwritable.modeNotSet(path: path, reason: "\(error)")
            }
        }

        /// Written as the file rather than through `defaults`, because that is how the
        /// answers are read back: onboarding parses this same path with this same
        /// serializer, and a write that went through another door would be a second way
        /// for one fact to be stored. Measured on this Mac: a direct write to the file is
        /// what `defaults read` reports a moment later, in both directions, so cfprefsd
        /// serves this domain from the file rather than from a cache in front of it.
        /// The bytes alone. The mode is `makeReadable`'s, asserted by the caller on every
        /// start rather than here on the starts that happen to write.
        func write(to path: String) throws(Unwritable) {
            do {
                try PropertyListSerialization
                    .data(fromPropertyList: root, format: .binary, options: 0)
                    .write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                throw Unwritable.notWritten(path: path, reason: "\(error)")
            }
        }
    }

    /// What went wrong, and what it costs the reader. Never swallowed into "filed": the
    /// consequence of believing it was is that the first dictation after an install types
    /// into a dialog, which is the whole reason this exists. [LAW:no-silent-failure]
    ///
    /// Each case says its own consequence, because they are not the same consequence and
    /// the caller cannot tell them apart. The two that leave the answer unfiled mean the
    /// assistant may take the first line typed; `modeNotSet` means the opposite - the
    /// answer is filed and the assistant is answered - and costs something else entirely,
    /// which is that onboarding's unprivileged read of the file may stop working. A caller
    /// framing every one of these as "could not file the answer" sent an operator looking
    /// for a dialog that was never going to appear, while the failure that had actually
    /// happened went unnamed. So the sentence lives here, per case, and the caller logs
    /// it rather than writing one of its own. [LAW:one-source-of-truth]
    enum Unwritable: Error, CustomStringConvertible, Equatable {
        case unreadable(path: String, reason: String)
        case notWritten(path: String, reason: String)
        /// Reachable only once the answer is filed - the content is written, or was
        /// already right, before the mode is ever asserted - so this case can say flatly
        /// that the filing landed. The cost is where it must hedge: the mode is asserted
        /// and never read back, so a `setAttributes` that fails for a reason of its own
        /// leaves the real mode unknown, and a file already at 0644 still reads fine. A
        /// flat "the read will fail" sent an operator after a permissions problem that
        /// may not be there. [LAW:no-silent-failure] wants the failure loud and true, and
        /// a consequence this case cannot know is not the failure it has.
        case modeNotSet(path: String, reason: String)

        var description: String {
            switch self {
            case .unreadable(let path, let reason):
                """
                could not read \(path), so this keyboard's answer was not filed and \
                nothing was overwritten, and Keyboard Setup Assistant may take the first \
                line typed: \(reason)
                """
            case .notWritten(let path, let reason):
                """
                could not write \(path), so this keyboard's answer was not filed and \
                Keyboard Setup Assistant may take the first line typed: \(reason)
                """
            case .modeNotSet(let path, let reason):
                """
                this keyboard's answer is filed and Keyboard Setup Assistant is answered, \
                but the mode on \(path) could not be asserted, so onboarding's unprivileged \
                read of it may fail: \(reason)
                """
            }
        }
    }
}
