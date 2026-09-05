import AppKit

/// Puts text at the focus by pasting it, and leaves the pasteboard holding what it
/// held before. The universal insertion fallback: every app that can paste takes it.
///
/// The text goes on the pasteboard, the receiver pastes, and the prior contents go
/// back once its paste has run. Nothing is timed, and nothing is read into who pulled
/// the pasteboard: a clipboard manager pulls every change and looks like a paste.
///
/// One inserter per pasteboard: inserts that overlap run one after another, so each
/// finds the pasteboard as the one before it left it.
@MainActor
public final class PasteInserter {
    /// nspasteboard.org's marker on the pasted item for something clipboard managers
    /// should not keep.
    nonisolated public static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let pasteboard: NSPasteboard
    private let oneAtATime = SerialQueue()

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Pastes `text` through `receiver` and puts the prior contents back, unless
    /// something else took the pasteboard meanwhile, in which case that stays. The
    /// prior contents go back whether or not the receiver managed to paste; when it
    /// did not, the thrown `InsertionFailed` says where the pasteboard was left.
    public func insert(_ text: String, into receiver: some PasteReceiver) async throws -> PasteOutcome {
        try await oneAtATime.run { @MainActor in try await self.paste(text, into: receiver) }
    }

    private func paste(_ text: String, into receiver: some PasteReceiver) async throws -> PasteOutcome {
        let prior = PasteboardContents(reading: pasteboard)
        let ours = pasteboard.clearContents()
        // AppKit refuses only an item already on another pasteboard, and it raises for
        // that; this item is fresh, so a refusal is AppKit broken, not a condition.
        precondition(pasteboard.writeObjects([Self.item(text)]), "AppKit refused a fresh pasteboard item")
        // [LAW:dataflow-not-control-flow] The restore runs on every path out; a failed
        // paste is reported after the pasteboard is back.
        let failure: (any Error)?
        do { try await receiver.paste(); failure = nil } catch { failure = error }
        let outcome = restore(prior, unlessTakenSince: ours)
        if let failure { throw InsertionFailed(reason: failure, pasteboard: outcome) }
        return outcome
    }

    /// Puts the prior contents back, unless the pasteboard has changed hands since
    /// `ours`, in which case whoever took it keeps it.
    ///
    /// [LAW:single-enforcer] The change count is the pasteboard's own word on whether
    /// it still holds our text, and only it decides whether to write.
    private func restore(_ prior: PasteboardContents, unlessTakenSince ours: Int) -> PasteOutcome {
        guard pasteboard.changeCount == ours else { return .pasteboardTaken }
        prior.write(to: pasteboard)
        return .restored
    }

    private static func item(_ text: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType)
        return item
    }
}

/// Where a paste left the pasteboard.
public enum PasteOutcome: Hashable, Sendable, CustomStringConvertible {
    /// Holding what it held before.
    case restored
    /// Holding what something else put there during the paste; that is left alone.
    case pasteboardTaken

    public var description: String {
        switch self {
        case .restored: "restored"
        case .pasteboardTaken: "left to whoever took it"
        }
    }
}

/// The receiver did not paste, or did not say that it had, and the pasteboard was
/// dealt with all the same.
///
/// [LAW:types-are-the-program] A failed insert still leaves the pasteboard somewhere;
/// the error carries where, so no caller has to guess.
public struct InsertionFailed: Error, CustomStringConvertible {
    public let reason: any Error
    public let pasteboard: PasteOutcome

    public var description: String { "\(reason); pasteboard \(pasteboard)" }
}
