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

    /// A keyboard that is up, where the daemon behind it came from - found running, or
    /// started here, in which case it is this helper's to stop - and what bringing it up
    /// cost. [LAW:types-are-the-program] Two origins, two duties, and no pid to wonder about.
    struct Reached {
        let keyboard: VirtualKeyboard
        let daemon: Origin
        let startup: VirtualKeyboard.Startup
    }

    enum Origin {
        case alreadyRunning
        case startedHere(pid_t)
    }

    struct CouldNotStart: Error, CustomStringConvertible {
        let code: Int32
        var description: String { "could not start \(executable): \(String(cString: strerror(code))) (\(code))" }
    }

    /// Brings the keyboard up, in at most `limit` altogether: connects to the daemon,
    /// starting it when it is not there to connect to, then starts the keyboard on it.
    ///
    /// [LAW:single-enforcer] The one unit that can leave a daemon running that this helper
    /// started, so it is the one that makes sure it does not: a daemon started here that
    /// never answers, or one whose keyboard will not start, is stopped before the failure
    /// leaves. The caller holds no pid to orphan. `whenLost` is told the daemon's origin
    /// with the loss, for the same reason: what it may stop is this unit's knowledge.
    static func reach(within limit: Duration, whenLost: @escaping @Sendable (DaemonError, Origin) -> Void) throws -> Reached {
        let deadline = ContinuousClock.now + limit
        let (keyboard, origin) = try connect(by: deadline, whenLost: whenLost)
        do {
            let startup = try keyboard.start(within: deadline - ContinuousClock.now)
            return Reached(keyboard: keyboard, daemon: origin, startup: startup)
        } catch {
            stop(origin)
            throw error
        }
    }

    /// A connection to the daemon and where the daemon came from.
    private static func connect(by deadline: ContinuousClock.Instant, whenLost: @escaping @Sendable (DaemonError, Origin) -> Void) throws -> (VirtualKeyboard, Origin) {
        do {
            return (try VirtualKeyboard { whenLost($0, .alreadyRunning) }, .alreadyRunning)
        } catch let unreachable as DaemonError {
            log("no daemon to reach (\(unreachable)); starting it")
        }
        let origin = Origin.startedHere(try start())
        while true {
            do {
                return (try VirtualKeyboard { whenLost($0, origin) }, origin)
            } catch let unreachable as DaemonError {
                guard ContinuousClock.now < deadline else { stop(origin); throw unreachable }
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
