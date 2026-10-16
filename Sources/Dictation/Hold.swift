import Insertion
import LowTalkerCore

/// What no cursor took, and what the latest try to place it was told.
///
/// [LAW:types-are-the-program] Two cases because a landing settles one and not the other.
public enum Held: Sendable, Equatable {
    /// Words at no cursor, in the order they were said, which the next insert carries ahead
    /// of its own, beside what an earlier insert whose words may have landed was told, while
    /// that warning stands.
    case unplaced(Transcript, warning: String, unaccounted: String? = nil)
    /// Words handed to an app that may yet take them, or sent with no answer to say what became
    /// of them. They are not offered again, since that is the one way to type them twice, and
    /// no later insert says what became of them, so the warning stands until the person
    /// dismisses it.
    case unaccounted(warning: String)

    /// The words the next insert carries.
    public var words: Transcript {
        switch self {
        case .unplaced(let words, _, _): words
        case .unaccounted: Transcript(words: [])
        }
    }

    /// What the person is told, oldest first.
    public var warnings: [String] {
        switch self {
        case .unplaced(_, let warning, let unaccounted): [unaccounted, warning].compactMap { $0 }
        case .unaccounted(let warning): [warning]
        }
    }

    /// The warning a landing leaves standing.
    var standing: String? {
        switch self {
        case .unplaced(_, _, let unaccounted): unaccounted
        case .unaccounted(let warning): warning
        }
    }
}

/// The words no cursor has taken, kept until one does or the person dismisses them. Brandon,
/// 2026-10-15: a dictation's words are never thrown away.
///
/// [LAW:no-shared-mutable-globals] One for the life of the app, so a loop rebuilt over a new
/// config keeps what the old one held. Written by the loop as it places words and by the
/// person through `dismiss`, and every change is told to `showing`.
@MainActor
public final class Hold {
    public private(set) var held: Held? {
        didSet { if held != oldValue { showing(held) } }
    }

    private let showing: @MainActor (Held?) -> Void

    public init(showing: @escaping @MainActor (Held?) -> Void) {
        self.showing = showing
    }

    /// The person let the held words go.
    public func dismiss() {
        held = nil
    }

    /// What the next insert carries: what is held, then `words`.
    func offering(_ words: Transcript) -> Transcript {
        Transcript(words: (held?.words.words ?? []) + words.words)
    }

    /// An insert carrying what was held landed, which says nothing of words unaccounted for.
    func landed() {
        held = held?.standing.map { .unaccounted(warning: $0) }
    }

    /// An insert of what is held and then `words` failed with `failure`. What is held is read
    /// now, not when the insert was offered, so words the person dismissed while it was on its
    /// way stay dismissed, and a warning that stands still stands. [LAW:one-source-of-truth]
    /// One whose words may have landed covers everything it carried, the held words with it,
    /// and stands in for a warning before it, which told the person the same thing.
    ///
    /// The person reads the warning, and the app logs it, so it is word-free whatever failed.
    func failed(_ words: Transcript, with failure: any Error) {
        let warning = (failure as? any WordFree).map { "\($0)" } ?? "WARNING: The insert failed on \(type(of: failure)). Your dictation was not inserted."
        held = wordsMayHaveLanded(after: failure)
            ? .unaccounted(warning: warning)
            : .unplaced(offering(words), warning: warning, unaccounted: held?.standing)
    }
}
