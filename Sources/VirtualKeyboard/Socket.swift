import Foundation

/// The two rules every socket in this module keeps, in the one place that keeps them.
///
/// Both sides of a socketpair need them and only one of them is a `DaemonConnection`, so
/// living on that type is what let the test fake be born without either. [LAW:single-enforcer]

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
