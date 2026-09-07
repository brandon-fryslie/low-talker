import Foundation

/// The two rules every socket in this module keeps, in the one place that keeps them.
///
/// They used to live on `DaemonConnection`, which is why a socket born anywhere else got
/// neither: the fake daemon on the other end of a socketpair is not a connection and had
/// no way to reach them. Here, neither side of the pair owns the other's rule.
/// [LAW:single-enforcer]

/// A write to a closed peer raises SIGPIPE, which ends the process without a word. Every
/// descriptor this module reads or writes refuses it at the moment it is created, and a
/// failure to set it is reported rather than assumed. [LAW:no-silent-failure]
func refuseSIGPIPE(_ descriptor: Int32) throws {
    var refuse: Int32 = 1
    guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &refuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw DaemonError.socket("setsockopt(SO_NOSIGPIPE)", errno)
    }
}

/// EINTR says the call did not happen and must be made again, which is the opposite of a
/// failure - and reporting a non-failure as one is the same lie as the reverse.
/// [LAW:no-silent-failure] A signal delivered during a run is enough to trip it.
func uninterrupted(_ call: () -> Int) -> Int {
    while true {
        let result = call()
        guard result < 0, errno == EINTR else { return result }
    }
}

/// Every wait on a socket in this module is a poll with a deadline, so the calls
/// themselves must never wait: a blocking write hands over a frame whole, and one larger
/// than the room the poll reported would wait for the rest with no deadline at all - under
/// the lock, with every waiter behind it. [LAW:no-ambient-temporal-coupling]
func neverBlock(_ descriptor: Int32) throws {
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
        throw DaemonError.socket("fcntl(O_NONBLOCK)", errno)
    }
}
