import Foundation
import Insertion
import os

/// Every change of the modifier keys a controller is handed, as the keys held once it
/// happened: what this process tells the app, so the app hears a chord of modifiers alone
/// with nothing granted to it.
///
/// [LAW:no-shared-mutable-globals] Shared for `FocusedClient`'s reason: `IMKServer` builds
/// controllers out of a class name, so there is no constructor of ours to hand a sender to.
/// It is one stream with one writer's door, `moved(at:)`, and one reader, the process's
/// entry point, which does the sending.
///
/// The state is read from the window server's session rather than off the event, because
/// the event the text input system hands over carries flags that do not tell Right Option
/// from Left, and the session's do - measured on studious, 2026-09-27: with both Option keys
/// down, each one's event carried 0x80000 and the session 0x80160, a bit for each side.
/// Reading it needs no grant. A state read a
/// moment after its event can already hold the next change, which costs nothing: the app
/// hears states, and a state is true whichever event it follows.
public final class ModifierChanges: Sendable {
    public static let shared = ModifierChanges()

    /// Each change, in the order the controllers were handed them. The newest are kept if
    /// the reader falls behind, since each carries the whole state and the latest is the one
    /// that is true. [LAW:no-ambient-temporal-coupling]
    public let changes: AsyncStream<HeldModifiers>
    private let continuation: AsyncStream<HeldModifiers>.Continuation
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "lowtalker-inputmethod", category: "modifiers")

    private init() {
        (changes, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    /// A controller was handed a change of the modifier keys, stamped `timestamp` seconds
    /// after the machine came up - `NSEvent.timestamp`, the clock the app's presses are on.
    public func moved(at timestamp: TimeInterval) {
        let reading = SessionModifiers.read()
        // [LAW:nothing-unseen] One record per change told: the only window into this process.
        log.info("modifiers moved at \(timestamp, privacy: .public): \(reading, privacy: .public)")
        continuation.yield(HeldModifiers(
            flags: reading.flags,
            // Rounded: seconds as a double do not land on whole nanoseconds.
            uptimeNanoseconds: UInt64((timestamp * 1_000_000_000).rounded())))
    }
}
