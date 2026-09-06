import Foundation
import VirtualKeyboard

/// Karabiner-VirtualHIDDevice-Daemon, the root process that holds the driver open, and
/// the one thing that has to be running before anything can type.
///
/// The public package installs it and registers nothing to run it: there is no launchd
/// job for it on a Mac that has never had Karabiner-Elements, so a driver that is
/// enabled and running per `scripts/virtual-hid-driver state` still types nothing. This
/// helper owns that lifecycle alongside its own. [LAW:no-ambient-temporal-coupling] It
/// reaches for the daemon first and starts it only when nothing answers, so a daemon
/// somebody else is running - by hand, or by Karabiner-Elements' own job - is used as it
/// stands rather than doubled.
enum DaemonProcess {
    static let executable = "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon"

    /// A keyboard connected to the daemon, and where the daemon came from: found running,
    /// or started here - in which case it is this helper's to stop.
    /// [LAW:types-are-the-program] Two origins, two duties, and no pid to wonder about.
    struct Reached {
        let keyboard: VirtualKeyboard
        let daemon: Origin
    }

    enum Origin {
        case alreadyRunning
        case startedHere(pid_t)
    }

    struct CouldNotStart: Error, CustomStringConvertible {
        let code: Int32
        var description: String { "could not start \(executable): \(String(cString: strerror(code))) (\(code))" }
    }

    /// Connects to the daemon, starting it when it is not there to connect to, in at most
    /// `limit` altogether.
    static func reach(within limit: Duration, whenLost: @escaping @Sendable (DaemonError) -> Void) throws -> Reached {
        do {
            return Reached(keyboard: try VirtualKeyboard(whenLost: whenLost), daemon: .alreadyRunning)
        } catch let unreachable as DaemonError {
            log("no daemon to reach (\(unreachable)); starting it")
        }
        let pid = try start()
        let deadline = ContinuousClock.now + limit
        while true {
            do {
                return Reached(keyboard: try VirtualKeyboard(whenLost: whenLost), daemon: .startedHere(pid))
            } catch is DaemonError where ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    /// Starts the daemon as this process's child. It outlives this process on purpose:
    /// a helper that exits because the connection dropped is restarted by launchd and
    /// finds the daemon where it left it, and only `stop` ends it.
    private static func start() throws -> pid_t {
        var pid: pid_t = 0
        let arguments: [UnsafeMutablePointer<CChar>?] = [strdup(executable), nil]
        defer { arguments.forEach { free($0) } }
        let spawned = posix_spawn(&pid, executable, nil, nil, arguments, environ)
        guard spawned == 0 else { throw CouldNotStart(code: spawned) }
        log("started the daemon as pid \(pid)")
        return pid
    }

    /// Ends the daemon this helper started. A daemon somebody else started is theirs to end.
    static func stop(_ origin: Origin) {
        switch origin {
        case .alreadyRunning:
            log("leaving the daemon running: this helper did not start it")
        case .startedHere(let pid):
            kill(pid, SIGTERM)
            log("stopped the daemon this helper started, pid \(pid)")
        }
    }
}
