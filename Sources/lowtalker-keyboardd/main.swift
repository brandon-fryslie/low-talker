import Foundation
import Keystrokes
import KeyboardService
import VirtualKeyboard

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
    /// way a connection can end.
    func releaseEverything() {
        attempt({ try $0.releaseAll() }) { error in
            if let error { log("a client went away and the keyboard would not release: \(error)") }
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
            domain: "com.lowtalker.keyboardd",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(error)"]
        )
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }
}

/// Accepts a connection when the caller is who the requirement says, and refuses it
/// otherwise.
final class Listener: NSObject, NSXPCListenerDelegate {
    private let keyboard: Keyboard
    private let callers: CallerIdentity

    init(keyboard: Keyboard, callers: CallerIdentity) {
        self.keyboard = keyboard
        self.callers = callers
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            guard let token = connection.callerAuditToken else { throw CallerIdentity.Refused.noAuditToken }
            try callers.check(auditToken: token)
        } catch {
            log("refused a connection: \(error)")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: KeyboardService.self)
        connection.exportedObject = keyboard
        // Both, and not one: an interrupted connection ends invalid, a closed one ends
        // interrupted, and a client killed mid-burst can take either path. The release is
        // idempotent, so running it twice costs a report and running it never costs the
        // operator a held key.
        connection.invalidationHandler = { [keyboard] in keyboard.releaseEverything() }
        connection.interruptionHandler = { [keyboard] in keyboard.releaseEverything() }
        connection.resume()
        log("accepted a connection")
        return true
    }
}

/// Said where launchd will keep it. A daemon's only voice is its log, and a daemon that
/// fails silently at startup looks exactly like one that is working.
func log(_ message: String) {
    FileHandle.standardError.write("lowtalker-keyboardd: \(message)\n".data(using: .utf8)!)
}

/// The requirement callers must satisfy, named by the job rather than compiled in.
///
/// There is no default. A helper that fell back to accepting anything when its
/// configuration was missing would be a root keystroke service open to every process on
/// the machine, arrived at by omission - the failure mode a default exists to hide.
/// [LAW:no-silent-failure]
guard let requirementText = ProcessInfo.processInfo.environment["LOWTALKER_CALLER_REQUIREMENT"] else {
    log("LOWTALKER_CALLER_REQUIREMENT is not set: the job must name the code signing requirement its callers have to satisfy")
    exit(78) // EX_CONFIG
}

do {
    let callers = try CallerIdentity(requirement: requirementText)
    let device = try VirtualKeyboard()
    let startup = try device.start(within: .seconds(10))
    log("the keyboard is up: the daemon answered in \(startup.answered), ready after \(startup.ready)")

    let listener = NSXPCListener(machServiceName: Helper.machServiceName)
    let delegate = Listener(keyboard: Keyboard(keyboard: device), callers: callers)
    listener.delegate = delegate
    listener.resume()
    log("listening on \(Helper.machServiceName)")
    // Held so the delegate outlives this scope; `resume` does not retain it.
    withExtendedLifetime(delegate) { dispatchMain() }
} catch {
    log("could not start: \(error)")
    exit(1)
}
