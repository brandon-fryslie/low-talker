import DriverExtension
import Flavors
import Foundation
import KeyboardService
import Signals
import VirtualKeyboard
import os

/// Which installation this helper serves, from the `--flavor` its plist passes.
///
/// Resolved before anything else, because every name below is read off it - the service
/// listened on, the subsystem logged under - and a helper that does not know which copy
/// it belongs to has nothing it can correctly do. A plist that does not say is a broken
/// installation rather than a passing condition, so this ends the process rather than
/// choosing for it. Exit 0 is the one code that stops launchd's KeepAlive from starting
/// it again, which is right here: starting again will not add the argument.
/// [LAW:no-silent-failure]
///
/// The refusal is logged under `Flavor.startupSubsystem`, not a service's: which service
/// this would have been is exactly what is not known. `scripts/keyboard-helper log` reads
/// that subsystem alongside the flavor's own, so this is findable by the one command a
/// reader already has. [LAW:no-silent-failure]
let flavor: Flavor = {
    guard let flavor = flavorArgument(CommandLine.arguments) else {
        Logger(subsystem: Flavor.startupSubsystem, category: "helper").fault(
            "will not start: no --flavor \(Flavor.allCases.map(\.description).joined(separator: " or "), privacy: .public) in \(CommandLine.arguments, privacy: .public)")
        exit(0)
    }
    return flavor
}()

/// Said where `log show` will find it, under this flavor's service name - which is what
/// keeps the two installations' logs apart. A daemon's only voice is its log, and a
/// daemon that fails silently at startup looks exactly like one that is working. Public
/// on purpose: nothing here is the user's data, and a redacted reason is no reason.
///
///     log show --last 10m --predicate 'subsystem == "com.lowtalker.keyboardd"'
private let logger = Logger(subsystem: flavor.machServiceName, category: "helper")
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

    // Before the devices come up, and that ordering is the whole point: macOS raises
    // Keyboard Setup Assistant when the keyboard ENUMERATES, so an answer filed after
    // `reach` would be a race with the dialog it exists to prevent.
    // [LAW:no-ambient-temporal-coupling]
    //
    // A failure here does not stop the helper. The keyboard still types; what is lost is
    // that the assistant may take the first line of it, which is worth saying loudly and
    // is not worth refusing to type over. Said here, and read back by onboarding's own
    // row, which stays unmet until the answer is actually on disk - so this is reported
    // twice and swallowed nowhere. [LAW:no-silent-failure]
    // The failure says what it cost, because only it knows: a mode that could not be set
    // leaves the answer filed and the assistant answered, and a frame written here would
    // have told an operator to expect a dialog that is never going to appear.
    // [LAW:one-source-of-truth] Typed, so this is every failure `file` has rather than
    // whichever ones were thought of here.
    do {
        let filing = try KeyboardTypeAnswer.file()
        log("this keyboard's answer \(filing) with Keyboard Setup Assistant under \(VirtualKeyboardIdentity.keyboardTypeKey)")
    } catch {
        log("\(error)")
    }

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

    let listener = NSXPCListener(machServiceName: flavor.machServiceName)
    let delegate = Listener(devices: devices, callers: callers)
    listener.delegate = delegate
    listener.resume()
    log("listening on \(flavor.machServiceName) as the \(flavor) installation")
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
