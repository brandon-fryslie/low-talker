import Foundation
import Keystrokes
import KeyboardService
import VirtualKeyboard

/// The keyboard as the listener serves it: what a client is handed, and the release made
/// on a client's behalf when it goes. [LAW:decomposition] Admitting and letting go are the
/// listener's; what a release is belongs to the keyboard, and a keyboard of a test's own
/// stands behind the real listener through this.
protocol ServedKeyboard: KeyboardService {
    func releaseEverything(because reason: String)
}

/// The keyboard, held open for the life of the daemon and served to one client at a time.
///
/// [LAW:no-ambient-temporal-coupling] The device is brought up at startup and never
/// re-opened per client, because readiness is not instant: pqrs's daemon asks the driver
/// whether the keyboard is ready on a one-second timer, so a connect-per-insert helper
/// would put up to a full second in front of the first keystroke of every dictation, for
/// a reason that has nothing to do with the hardware. Paid once here, where nobody is
/// waiting.
final class Keyboard: NSObject, ServedKeyboard, @unchecked Sendable {
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
            reply(refusal(error))
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
/// "it did not work" to an operator holding a half-typed line. So the description is made
/// on this side, where the real error still exists, and carried by a plain `NSError` - the
/// one class the reply admits, and one every client has. A subclass of it would be
/// archived under a name no client links, and would not decode. [LAW:no-silent-failure]
func refusal(_ error: any Error) -> NSError {
    NSError(domain: Helper.machServiceName, code: 1, userInfo: [NSLocalizedDescriptionKey: "\(error)"])
}
