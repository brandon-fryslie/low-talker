import Foundation

/// What went wrong with the daemon, in the words of what it did or did not say.
///
/// It lives in its own file because both layers below and above it raise it: the framing,
/// which touches no socket, and the connection, which is all socket. Either owning the
/// other's error vocabulary would make the pure half depend on the impure one for nothing
/// but a name. [LAW:one-way-deps]
public enum DaemonError: Error, CustomStringConvertible, Equatable {
    case noSocket(path: String)
    case socket(String, Int32)
    case silent
    case closed
    /// A frame that is not one. The message names no sender: the framing is read from both
    /// ends of a socketpair in the tests, and an error that says "the daemon sent" about
    /// bytes this side wrote points a maintainer at the wrong half of the module.
    case malformed(String)
    case driverVersionMismatched

    public var description: String {
        switch self {
        case .noSocket(let path):
            "no socket at \(path); Karabiner-VirtualHIDDevice-Daemon is not running, and only root can see it when it is"
        case .socket(let call, let code):
            "\(call) on the daemon's socket failed: \(String(cString: strerror(code))) (\(code))"
        case .silent:
            "the daemon did not answer in time"
        case .closed:
            "the daemon closed the connection"
        case .malformed(let what):
            "the wire carried \(what)"
        case .driverVersionMismatched:
            "the daemon reports the driver's version is not the one it was built for"
        }
    }
}
