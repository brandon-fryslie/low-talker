import Insertion
import LowTalkerCore

/// Words no cursor took, and what the latest try to place them was told.
public struct Held: Sendable, Equatable {
    /// The words at no cursor, in the order they were said. Empty after a failure that handed
    /// them to an app that may yet take them: those are not offered again, since that is the
    /// one way to type them twice.
    public let words: Transcript
    /// What the latest insert was told, as the person reads it.
    public let warning: String

    public init(words: Transcript, warning: String) {
        self.words = words
        self.warning = warning
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

    /// An insert carrying what was held landed.
    func landed() {
        held = nil
    }

    /// An insert of `offered` failed with `failure`: its words are held, unless the failure
    /// says they may have landed after all.
    func failed(_ offered: Transcript, with failure: any Error) {
        held = Held(words: wordsMayHaveLanded(after: failure) ? Transcript(words: []) : offered, warning: "\(failure)")
    }
}
