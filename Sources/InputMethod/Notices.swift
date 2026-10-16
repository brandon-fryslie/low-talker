import Foundation
import Insertion
import os

/// What this process tells the app, in the order it happened: every change of the modifier
/// keys a controller is handed, as the keys held once it happened, so the app hears a chord of
/// modifiers alone with nothing granted to it; and every cursor a controller is given focus in,
/// so the app can offer words no cursor took to the one that just arrived.
///
/// [LAW:no-shared-mutable-globals] Shared for `FocusedClient`'s reason: `IMKServer` builds
/// controllers out of a class name, so there is no constructor of ours to hand a sender to.
/// It is one stream with two writers' doors, `moved(at:reading:)` and `cursorArrived()`, and
/// one reader, the process's entry point, which does the sending.
///
/// The state the controller hands it is read from the window server's session rather than
/// off the event, because
/// the event the text input system hands over carries flags that do not tell Right Option
/// from Left, and the session's do - measured on studious, 2026-09-27: with both Option keys
/// down, each one's event carried 0x80000 and the session 0x80160, a bit for each side.
/// Reading it needs no grant. A state read a
/// moment after its event can already hold the next change, which costs nothing: the app
/// hears states, and a state is true whichever event it follows. It is dated by the session's
/// last change for the same reason, since the event's stamp would put a release the reading
/// already shows back at the earlier event, and turn a hold into a tap.
public final class Notices: Sendable {
    public static let shared = Notices()

    /// Each notice, in the order the controllers were handed them. The newest are kept if
    /// the reader falls behind, since each change carries the whole state and the latest is
    /// the one that is true. [LAW:no-ambient-temporal-coupling]
    public let notices: AsyncStream<Notice>
    private let continuation: AsyncStream<Notice>.Continuation
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "lowtalker-inputmethod", category: "modifiers")

    private init() {
        (notices, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    /// A controller was handed a change of the modifier keys stamped `timestamp` seconds
    /// after the machine came up - `NSEvent.timestamp`, the clock the app's presses are on -
    /// and read the session as `reading` when it handled it.
    public func moved(at timestamp: TimeInterval, reading: SessionModifiers) {
        // [LAW:nothing-unseen] One record per change told: the only window into this process.
        // The event's stamp is here and nowhere else, so a reading that ran ahead of its event
        // shows as the gap between it and the reading's date.
        log.info("modifiers moved at \(timestamp, privacy: .public): \(reading, privacy: .public)")
        continuation.yield(.modifiersMoved(HeldModifiers(reading)))
    }

    /// A controller was given focus in a cursor that can take words, in `application`.
    public func cursorArrived(in application: String) {
        log.info("a cursor arrived in \(application, privacy: .public)")
        continuation.yield(.cursorArrived)
    }
}
