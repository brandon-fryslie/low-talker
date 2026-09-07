import Foundation
import Keystrokes
import KeyboardService
import Pointing
import VirtualKeyboard

/// The devices as the listener serves them: what a client is handed, and the release made
/// on a client's behalf when it goes. [LAW:decomposition] Admitting and letting go are the
/// listener's; what a release is belongs to the devices, and devices of a test's own stand
/// behind the real listener through this.
protocol ServedDevices: HelperService {
    func releaseEverything(because reason: String)
}

/// The keyboard and the mouse, held open for the life of the daemon and served to one
/// client at a time.
///
/// [LAW:no-ambient-temporal-coupling] Both are brought up at startup and never re-opened
/// per client, because readiness is not instant: pqrs's daemon asks the driver whether a
/// device is ready on a one-second timer, so a connect-per-insert helper would put up to
/// a full second in front of the first keystroke of every dictation, for a reason that has
/// nothing to do with the hardware. Paid once here, where nobody is waiting.
final class Devices: NSObject, ServedDevices, @unchecked Sendable {
    private let keyboard: VirtualKeyboard
    private let mouse: VirtualPointing
    /// One report at a time, across both devices. [LAW:no-shared-mutable-globals] Each
    /// device derives every report from the set it believes is down, so two calls
    /// interleaving on one device would each post a report missing the other's - which
    /// the driver reads as a release nobody sent. The two devices share the lock because
    /// they share the socket and the client: a keyboard report and a mouse report from one
    /// client are one sequence, and ordering them is cheaper than reasoning about two.
    ///
    /// A lock and not a queue, because every call here is a round trip the client is
    /// already waiting on: hopping to another thread to do synchronous work would add a
    /// hop and take away the ability to answer on the thread that asked.
    private let device = NSLock()

    init(keyboard: VirtualKeyboard, mouse: VirtualPointing) {
        self.keyboard = keyboard
        self.mouse = mouse
    }

    /// [LAW:dataflow-not-control-flow] Every call is the same act - take the devices, do
    /// one thing to them, answer with what happened - so they are one function taking the
    /// thing to do, not six copies of the same locking and error handling.
    private func attempt(_ act: () throws -> Void, _ reply: (Error?) -> Void) {
        device.lock()
        defer { device.unlock() }
        do {
            try act()
            reply(nil)
        } catch {
            reply(refusal(error))
        }
    }

    func down(usage: UInt16, reply: @escaping (Error?) -> Void) {
        attempt({ try keyboard.down(Usage(rawValue: usage)) }, reply)
    }

    func releaseAll(reply: @escaping (Error?) -> Void) {
        attempt({ try keyboard.releaseAll() }, reply)
    }

    func buttonDown(_ button: UInt8, reply: @escaping (Error?) -> Void) {
        attempt({ try mouse.down(try Self.button(button)) }, reply)
    }

    func releaseButtons(reply: @escaping (Error?) -> Void) {
        attempt({ try mouse.releaseAll() }, reply)
    }

    func move(x: Int8, y: Int8, reply: @escaping (Error?) -> Void) {
        attempt({ try mouse.move(by: Move(x: try Self.count(x), y: try Self.count(y))) }, reply)
    }

    func scroll(vertical: Int8, horizontal: Int8, reply: @escaping (Error?) -> Void) {
        attempt({ try mouse.scroll(by: Scroll(vertical: try Self.count(vertical), horizontal: try Self.count(horizontal))) }, reply)
    }

    /// Releases everything the client that just went away had left held, on both devices.
    ///
    /// [LAW:single-enforcer] A client that crashes mid-character leaves a key down, and a
    /// key the driver believes is down is one macOS repeats into whatever comes forward
    /// next - the failure this whole epic exists to avoid. A button left down is a drag
    /// macOS continues across whatever the pointer crosses. The client cannot clean up
    /// after itself in precisely the case that matters, so the helper does it, on every
    /// way a connection can end - and on its own way out, for the same reason. Each device
    /// is released whatever the other answered.
    func releaseEverything(because reason: String) {
        attempt({ try keyboard.releaseAll() }) { error in
            log(error.map { "\(reason), and the keyboard would not release: \($0)" } ?? "\(reason); every key is up")
        }
        attempt({ try mouse.releaseAll() }) { error in
            log(error.map { "\(reason), and the mouse would not release: \($0)" } ?? "\(reason); every button is up")
        }
    }

    /// [LAW:parse-dont-validate] The wire's byte is wider than the device on both counts -
    /// button 0 and 33 upward have no bit, and -128 is below the descriptor's minimum -
    /// and a value the device cannot carry is refused here by name, once, rather than
    /// folded to the nearest one it can.
    private static func button(_ number: UInt8) throws -> Button {
        guard let button = Button(rawValue: number) else { throw NotOnTheDevice.button(number) }
        return button
    }

    private static func count(_ value: Int8) throws -> Count {
        guard let count = Count(exactly: value) else { throw NotOnTheDevice.count(value) }
        return count
    }
}

/// A value the wire can carry and the device cannot.
enum NotOnTheDevice: Error, CustomStringConvertible {
    case button(UInt8)
    case count(Int8)

    var description: String {
        switch self {
        case .button(let number): "button \(number) is not one of the 32 the device has a bit for"
        case .count(let value): "\(value) is outside the -127 through 127 a report carries"
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
