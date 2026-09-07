import Foundation

/// Which connection has the keyboard. One at a time, because there is one keyboard: two
/// clients typing through the same set of held keys would each post reports missing the
/// other's, and the first to leave would release the keys the other was holding.
/// [LAW:types-are-the-program] Refusal is the truthful answer to a second client, and a
/// client that wants to share can connect per insert - the connection is lazy, and the
/// helper paid for readiness once.
///
/// Connections are named by identifier and not held: a holder that kept the connection
/// would keep it alive, and the release runs from a handler the connection itself owns.
final class Holder: @unchecked Sendable {
    struct Busy: Error, CustomStringConvertible {
        let pid: pid_t
        var description: String { "pid \(pid) holds the keyboard" }
    }

    private let lock = NSLock()
    private var holding: (connection: ObjectIdentifier, pid: pid_t)?

    /// The keyboard is `connection`'s until it is released, or `Busy` names whose it is.
    func claim(_ connection: ObjectIdentifier, by pid: pid_t) throws {
        lock.lock(); defer { lock.unlock() }
        if let holding { throw Busy(pid: holding.pid) }
        holding = (connection, pid)
    }

    /// Frees the keyboard when `connection` holds it, and changes nothing when it does
    /// not: a connection that was refused never held it, and its ending must not free
    /// the keyboard from under the one that does.
    func release(_ connection: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        if holding?.connection == connection { holding = nil }
    }
}
