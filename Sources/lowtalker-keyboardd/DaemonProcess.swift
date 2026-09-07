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
    struct Reached<Keyboard> {
        let keyboard: Keyboard
        let daemon: Origin
        let startup: VirtualKeyboard.Startup
    }

    enum Origin: Equatable {
        case alreadyRunning
        case startedHere(pid_t)
    }

    struct CouldNotStart: Error, CustomStringConvertible {
        let code: Int32
        var description: String { "could not start \(executable): \(String(cString: strerror(code))) (\(code))" }
    }

    /// What reaching the daemon does to the world, taken as values: connect to it, bring
    /// the keyboard up on the connection, launch the daemon, terminate it. The policy over
    /// them - reach first, launch only when nothing answers, stop only what was launched
    /// here - is then a function of what they answer, and a test drives it with answers of
    /// its own and no daemon at all. [LAW:effects-at-boundaries]
    struct Effects<Keyboard> {
        /// A connection to a daemon that is running, or `DaemonError` when none answers.
        /// `whenLost` is told when that connection ends underneath the keyboard.
        let connect: (_ whenLost: @escaping @Sendable (DaemonError) -> Void) throws -> Keyboard
        /// The keyboard brought up on its connection, within the limit.
        let bringUp: (Keyboard, Duration) throws -> VirtualKeyboard.Startup
        /// The daemon started as this process's child.
        let launch: () throws -> pid_t
        let terminate: (pid_t) -> Void
    }

    /// The effects done for real. The daemon outlives this process on purpose: a helper
    /// that exits because the connection dropped is restarted by launchd and finds the
    /// daemon where it left it, and only `stop` ends it.
    static var real: Effects<VirtualKeyboard> {
        Effects(
            connect: { try VirtualKeyboard(whenLost: $0) },
            bringUp: { try $0.start(within: $1) },
            launch: spawn,
            terminate: { kill($0, SIGTERM) }
        )
    }

    private static func spawn() throws -> pid_t {
        var pid: pid_t = 0
        let arguments: [UnsafeMutablePointer<CChar>?] = [strdup(executable), nil]
        defer { arguments.forEach { free($0) } }
        let spawned = posix_spawn(&pid, executable, nil, nil, arguments, environ)
        guard spawned == 0 else { throw CouldNotStart(code: spawned) }
        return pid
    }
}

extension DaemonProcess.Effects {
    /// Brings the keyboard up: connects to the daemon, starting it when it is not there to
    /// connect to, then starts the keyboard on the connection. Each of the two is given
    /// the whole of `limit`: a socket that answers and a driver that reports ready are
    /// different waits, so neither is handed what the other left.
    /// [LAW:no-ambient-temporal-coupling]
    ///
    /// [LAW:single-enforcer] The one unit that can leave a daemon running that this helper
    /// started, so it is the one that makes sure it does not: a daemon started here that
    /// never answers, or one whose keyboard will not start, is stopped before the failure
    /// leaves. The caller holds no pid to orphan. `whenLost` is told the daemon's origin
    /// with the loss, for the same reason: what it may stop is this unit's knowledge.
    func reach(within limit: Duration, whenLost: @escaping @Sendable (DaemonError, DaemonProcess.Origin) -> Void) throws -> DaemonProcess.Reached<Keyboard> {
        let (keyboard, origin) = try connection(by: .now + limit, whenLost: whenLost)
        do {
            return DaemonProcess.Reached(keyboard: keyboard, daemon: origin, startup: try bringUp(keyboard, limit))
        } catch {
            stop(origin)
            throw error
        }
    }

    /// A connection to the daemon and where the daemon came from.
    private func connection(by deadline: ContinuousClock.Instant, whenLost: @escaping @Sendable (DaemonError, DaemonProcess.Origin) -> Void) throws -> (Keyboard, DaemonProcess.Origin) {
        do {
            return (try connect { whenLost($0, .alreadyRunning) }, .alreadyRunning)
        } catch let unreachable as DaemonError {
            log("no daemon to reach (\(unreachable)); starting it")
        }
        let pid = try launch()
        log("started the daemon as pid \(pid)")
        let origin = DaemonProcess.Origin.startedHere(pid)
        while true {
            do {
                return (try connect { whenLost($0, origin) }, origin)
            } catch let unreachable as DaemonError {
                guard ContinuousClock.now < deadline else { stop(origin); throw unreachable }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    /// Ends the daemon this helper started. A daemon somebody else started is theirs to end.
    func stop(_ origin: DaemonProcess.Origin) {
        switch origin {
        case .alreadyRunning:
            log("leaving the daemon running: this helper did not start it")
        case .startedHere(let pid):
            terminate(pid)
            log("stopped the daemon this helper started, pid \(pid)")
        }
    }
}
