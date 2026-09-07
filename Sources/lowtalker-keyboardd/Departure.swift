import Foundation

/// The one way out of this process, claimed by whichever reason to leave comes first.
///
/// [LAW:no-ambient-temporal-coupling] Two things end the helper - launchd's SIGTERM, and
/// the daemon's connection going - and each can set the other off. Leaving on SIGTERM
/// releases the keys, which is a request; a request whose write fails is the connection
/// being lost, and the loss is reported on the thread that wrote, inside the release.
/// Without a claim, a clean stop whose daemon had just gone found the loss inside its
/// own shutdown and left through the loss handler with status 1, and launchd, told to
/// restart after an unsuccessful exit, started again what it had just asked to stop. The
/// first to claim is the one that ends the process; the other returns to a process that
/// is already on its way out. [LAW:single-enforcer]
final class Departure: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// True for the first caller and false for every later one.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { claimed = true }
        return !claimed
    }
}
