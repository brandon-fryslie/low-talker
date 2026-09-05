import AppKit
import Carbon.HIToolbox

/// Puts text at the focus by pasting it, and leaves the pasteboard holding what it
/// held before. The universal insertion fallback: every app that can paste takes it.
///
/// The text goes on the pasteboard as a promise, so the pasteboard server calls back
/// the moment the frontmost app pulls it. That call is what "the paste has landed"
/// means here; nothing is timed. The wait is bounded so a focus that never pastes
/// still gets the user's pasteboard back.
///
/// One inserter per pasteboard: inserts that overlap run one after another, so each
/// finds the pasteboard as the one before it left it.
@MainActor
public final class PasteInserter {
    nonisolated public static let defaultLandingTimeout: Duration = .seconds(1)
    nonisolated public static let pasteChord = KeyChord(key: Key(rawValue: UInt16(kVK_ANSI_V)), modifiers: [.leftCommand])
    /// nspasteboard.org's marker on the pasted item for something clipboard managers
    /// should not keep. It also keeps the managers that honor it from pulling the text
    /// themselves, which would look like a landing.
    nonisolated public static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let pasteboard: NSPasteboard
    private let keys: any KeyPoster
    private let landingTimeout: Duration
    private let oneAtATime = SerialQueue()

    public init(pasteboard: NSPasteboard = .general, keys: any KeyPoster = SystemKeyPoster(), landingTimeout: Duration = defaultLandingTimeout) {
        self.pasteboard = pasteboard
        self.keys = keys
        self.landingTimeout = landingTimeout
    }

    /// Pastes `text` into the frontmost app and puts the prior contents back, unless
    /// something else took the pasteboard meanwhile, in which case that stays.
    public func insert(_ text: String) async throws -> PasteOutcome {
        try await oneAtATime.run { @MainActor in try await self.paste(text) }
    }

    private func paste(_ text: String) async throws -> PasteOutcome {
        let prior = PasteboardContents(reading: pasteboard)
        let (landing, onLanding) = AsyncStream.makeStream(of: Void.self)
        let promise = TextPromise(text: text, landing: onLanding)
        let ours = pasteboard.clearContents()
        // AppKit refuses only an item already on another pasteboard, and it raises for
        // that; this item is fresh, so a refusal is AppKit broken, not a condition.
        precondition(pasteboard.writeObjects([promise.item()]), "AppKit refused a fresh pasteboard item")
        keys.post(Self.pasteChord)
        let landed = await Self.awaitLanding(landing, within: landingTimeout)
        return PasteOutcome(landed: landed, restored: restore(prior, unlessTakenSince: ours))
    }

    /// Puts the prior contents back, unless the pasteboard has changed hands since
    /// `ours`, in which case whoever took it keeps it and this returns false.
    ///
    /// [LAW:single-enforcer] The change count is the pasteboard's own word on whether
    /// it still holds our text; the promise being withdrawn says the same thing
    /// earlier, but only this decides whether to write, for every path out of a paste.
    private func restore(_ prior: PasteboardContents, unlessTakenSince ours: Int) -> Bool {
        guard pasteboard.changeCount == ours else { return false }
        prior.write(to: pasteboard)
        return true
    }

    /// True when the text was pulled before the timeout. The stream ending without an
    /// element is the promise withdrawn: something else took the pasteboard first.
    private static func awaitLanding(_ landing: AsyncStream<Void>, within timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in landing { return true }
                return false
            }
            group.addTask {
                // Cancellation cuts the sleep short when the other arm wins; both ways
                // out of the sleep mean no landing from this arm.
                _ = try? await Task.sleep(for: timeout)
                return false
            }
            // Two children were added, so a first result exists.
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }
}

/// What a paste leaves behind: two facts that vary on their own.
public struct PasteOutcome: Hashable, Sendable {
    /// The frontmost app pulled the text before the wait ran out.
    public let landed: Bool
    /// The pasteboard holds what it held before. False when something else took it
    /// during the paste; that is left alone.
    public let restored: Bool

    public init(landed: Bool, restored: Bool) {
        self.landed = landed
        self.restored = restored
    }
}

/// The text as a promised pasteboard item. The pasteboard server asks for the bytes
/// when a reader wants them, which is the landing signal, and says when the promise
/// is withdrawn, which ends the wait early.
///
/// AppKit delivers both callbacks through the main run loop, so the waiter on the main
/// actor cannot run while the text is being set. The protocol declares them
/// nonisolated; the precondition makes a delivery anywhere else a trap, not a race.
@MainActor
private final class TextPromise: NSObject, NSPasteboardItemDataProvider {
    private let text: String
    private let landing: AsyncStream<Void>.Continuation

    init(text: String, landing: AsyncStream<Void>.Continuation) {
        self.text = text
        self.landing = landing
    }

    func item() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(Data(), forType: PasteInserter.transientType)
        item.setDataProvider(self, forTypes: [.string])
        return item
    }

    /// The request is the landing; the bytes follow. Delivering the only promised type
    /// ends the promise, and AppKit says so from inside `setString`, so the yield has
    /// to come first.
    nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        MainActor.preconditionIsolated()
        landing.yield()
        item.setString(text, forType: type)
    }

    nonisolated func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        MainActor.preconditionIsolated()
        landing.finish()
    }
}
