import Foundation
import KeyboardService
import Signals
import VirtualKeyboard
import os

/// Said where `log show` will find it, under this service's name. A daemon's only voice
/// is its log, and a daemon that fails silently at startup looks exactly like one that
/// is working. Public on purpose: nothing here is the user's data, and a redacted reason
/// is no reason.
///
///     log show --last 10m --predicate 'subsystem == "com.lowtalker.keyboardd"'
private let logger = Logger(subsystem: Helper.machServiceName, category: "helper")
func log(_ message: String) {
    logger.notice("\(message, privacy: .public)")
}

/// Stops the daemon this process started and ends. The way out for every reason this
/// process ends on purpose, reached only by whoever claimed the departure.
/// [LAW:single-enforcer]
func leave(_ daemon: DaemonProcess.Origin, because reason: String, status: Int32) -> Never {
    DaemonProcess.real.stop(daemon)
    log("\(reason); exiting \(status)")
    exit(status)
}

do {
    let callers = try CallerIdentity.sameSignerAsThisProcess()
    log("callers must satisfy: \(callers.text)")
    let departure = Departure()

    // The connection is lost on the reading thread, and no key can be released over a
    // connection that is gone. What can be done is to stop the daemon this helper
    // started, which takes the device and whatever it held down with it; a daemon
    // somebody else runs stays theirs. Then end: launchd restarts this job after an
    // unsuccessful exit, and the next start reaches or restarts the daemon.
    // [LAW:no-silent-failure] A loss found while already leaving is that departure's to
    // finish, with the status it chose.
    let reached = try DaemonProcess.real.reach(within: .seconds(10)) { lost, daemon in
        guard departure.claim() else { return }
        leave(daemon, because: "the daemon's connection was lost (\(lost)); exiting for launchd to start this again", status: 1)
    }
    log("the keyboard is up: the daemon answered in \(reached.startup.keyboard.answered), ready after \(reached.startup.keyboard.ready)")
    log("the mouse is up: the daemon answered in \(reached.startup.mouse.answered), ready after \(reached.startup.mouse.ready)")
    let devices = Devices(keyboard: reached.devices.keyboard, mouse: reached.devices.mouse)
    // Whatever the daemon was holding for its last occupant - a helper that exited on a
    // lost connection while the daemon lived on, or a hand-run session - is up before
    // any client is served. Unconditionally: the daemon's origin says who started it,
    // not what it holds. [LAW:dataflow-not-control-flow]
    devices.releaseEverything(because: "starting")

    // launchd stops a job with SIGTERM. The departure is claimed before the keys are
    // released: the release is a request, and a request that finds the daemon gone
    // reports the loss on this thread, into the handler above, which must find the
    // departure already taken. [LAW:no-ambient-temporal-coupling]
    // The stop is handed the one value it uses, not the whole of what reaching returned.
    let origin = reached.daemon
    let termination = SignalWatch(on: [SIGTERM], answeringOn: .main) { _ in
        guard departure.claim() else { return }
        devices.releaseEverything(because: "asked to stop")
        leave(origin, because: "asked to stop", status: 0)
    }

    let listener = NSXPCListener(machServiceName: Helper.machServiceName)
    let delegate = Listener(devices: devices, callers: callers)
    listener.delegate = delegate
    listener.resume()
    log("listening on \(Helper.machServiceName)")
    // Held so the delegate and the watch outlive this scope; `resume` retains neither
    // the listener nor the sources the watch owns.
    withExtendedLifetime((delegate, termination)) { dispatchMain() }
} catch let refused as CallerIdentity.Refused {
    // The installation is wrong and starting again will not fix it. launchd cannot be
    // told EX_CONFIG: KeepAlive restarts on anything but a successful exit, so 0 is the
    // one code that says do not start this again. The reason is in the log.
    log("will not start: \(refused)")
    exit(0)
} catch {
    log("could not start: \(error)")
    exit(1)
}
