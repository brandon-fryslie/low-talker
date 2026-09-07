import Foundation
import Keystrokes
import KeyboardService
import VirtualKeyboard
import os

/// The keyboard, held open for the life of the daemon and served to one client at a time.
///
/// [LAW:no-ambient-temporal-coupling] The device is brought up at startup and never
/// re-opened per client, because readiness is not instant: pqrs's daemon asks the driver
/// whether the keyboard is ready on a one-second timer, so a connect-per-insert helper
/// would put up to a full second in front of the first keystroke of every dictation, for
/// a reason that has nothing to do with the hardware. Paid once here, where nobody is
/// waiting.
final class Keyboard: NSObject, KeyboardService, @unchecked Sendable {
    private let keyboard: VirtualKeyboard
    /// One report at a time. [LAW:no-shared-mutable-globals] `VirtualKeyboard` derives
    /// every report from the set of keys it believes are down, so two calls interleaving
    /// would each post a report missing the other's keys - which the driver reads as a
    /// key-up nobody sent, and macOS reads as a key to stop repeating.
    ///
    /// A lock and not a queue, because every call here is a round trip the client is
    /// already waiting on: hopping to another thread to do synchronous work would add a
    /// hop and take away the ability to answer on the thread that asked.
    private let device = NSLock()

    init(keyboard: VirtualKeyboard) {
        self.keyboard = keyboard
    }

    /// [LAW:dataflow-not-control-flow] Both calls are the same act - take the device, do
    /// one thing to it, answer with what happened - so they are one function taking the
    /// thing to do, not two copies of the same locking and error handling.
    private func attempt(_ act: (VirtualKeyboard) throws -> Void, _ reply: (Error?) -> Void) {
        device.lock()
        defer { device.unlock() }
        do {
            try act(keyboard)
            reply(nil)
        } catch {
            reply(Failure(error))
        }
    }

    func down(usage: UInt16, reply: @escaping (Error?) -> Void) {
        attempt({ try $0.down(Usage(rawValue: usage)) }, reply)
    }

    func releaseAll(reply: @escaping (Error?) -> Void) {
        attempt({ try $0.releaseAll() }, reply)
    }

    /// Releases everything the client that just went away had left held.
    ///
    /// [LAW:single-enforcer] A client that crashes mid-character leaves a key down, and a
    /// key the driver believes is down is one macOS repeats into whatever comes forward
    /// next - the failure this whole epic exists to avoid. The client cannot clean up
    /// after itself in precisely the case that matters, so the helper does it, on every
    /// way a connection can end - and on its own way out, for the same reason.
    func releaseEverything(because reason: String) {
        attempt({ try $0.releaseAll() }) { error in
            log(error.map { "\(reason), and the keyboard would not release: \($0)" } ?? "\(reason); every key is up")
        }
    }
}

/// An error a client can actually receive.
///
/// NSXPC carries only what it can encode, and a Swift error is not that: an unencodable
/// error crosses as a generic failure that names nothing, which is the same as saying
/// "it did not work" to an operator holding a half-typed line. The description is made on
/// this side, where the real error still exists. [LAW:no-silent-failure]
final class Failure: NSError, @unchecked Sendable {
    init(_ error: any Error) {
        super.init(
            domain: Helper.machServiceName,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(error)"]
        )
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }
}

/// Accepts a connection when the caller is who the requirement says and nobody else has
/// the keyboard, and refuses it otherwise, saying why.
final class Listener: NSObject, NSXPCListenerDelegate {
    private let keyboard: Keyboard
    private let callers: CallerIdentity
    private let holder = Holder()

    init(keyboard: Keyboard, callers: CallerIdentity) {
        self.keyboard = keyboard
        self.callers = callers
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            guard let token = connection.callerAuditToken else { throw CallerIdentity.Refused.noAuditToken }
            try callers.check(auditToken: token)
            try holder.claim(ObjectIdentifier(connection), by: connection.processIdentifier)
        } catch {
            log("refused a connection from pid \(connection.processIdentifier): \(error)")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: KeyboardService.self)
        connection.exportedObject = keyboard
        // Both, and not one: an interrupted connection ends invalid, a closed one ends
        // interrupted, and a client killed mid-burst can take either path. The release is
        // idempotent, so running it twice costs a report and running it never costs the
        // operator a held key. The keyboard is free for the next client only once this
        // one's keys are up, which is why invalidation releases the holder last.
        let id = ObjectIdentifier(connection)
        connection.invalidationHandler = { [keyboard, holder] in
            keyboard.releaseEverything(because: "a client went away")
            holder.release(id)
        }
        connection.interruptionHandler = { [keyboard] in keyboard.releaseEverything(because: "a client was interrupted") }
        connection.resume()
        log("accepted a connection from pid \(connection.processIdentifier)")
        return true
    }
}

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
    DaemonProcess.stop(daemon)
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
    let reached = try DaemonProcess.reach(within: .seconds(10)) { lost, daemon in
        guard departure.claim() else { return }
        leave(daemon, because: "the daemon's connection was lost (\(lost)); exiting for launchd to start this again", status: 1)
    }
    log("the keyboard is up: the daemon answered in \(reached.startup.answered), ready after \(reached.startup.ready)")
    let keyboard = Keyboard(keyboard: reached.keyboard)

    // launchd stops a job with SIGTERM. Taken as an event rather than the default
    // disposition, which would end the process with whatever was held still held. The
    // departure is claimed before the keys are released: the release is a request, and
    // a request that finds the daemon gone reports the loss on this thread, into the
    // handler above, which must find the departure already taken. [LAW:no-ambient-temporal-coupling]
    signal(SIGTERM, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    termination.setEventHandler {
        guard departure.claim() else { return }
        keyboard.releaseEverything(because: "asked to stop")
        leave(reached.daemon, because: "asked to stop", status: 0)
    }
    termination.resume()

    let listener = NSXPCListener(machServiceName: Helper.machServiceName)
    let delegate = Listener(keyboard: keyboard, callers: callers)
    listener.delegate = delegate
    listener.resume()
    log("listening on \(Helper.machServiceName)")
    // Held so the delegate and the signal source outlive this scope; `resume` retains
    // neither.
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
