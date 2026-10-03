import Carbon.HIToolbox
import CoreGraphics
import Darwin
import DarwinCalls
import Identity
import Foundation

/// The modifier keys held at one moment, as the input method read them the moment it was
/// handed a change of them: what crosses from the input method to the app, so the app can
/// hear a chord of modifiers alone with no grant of its own.
///
/// The whole state and not the key that moved. The text input system hands an input method
/// flags that do not tell Right Option from Left, so the state is read from the window
/// server's session instead, which does, and a state read that way can be ahead of the event
/// that prompted it. A state is true whichever event it follows, and one that has not changed
/// is recognisably nothing; a key named as having moved would be neither.
/// [FRAMING:representation]
public struct HeldModifiers: Equatable, Sendable {
    /// The session's modifier flags, device-side bits included: a `CGEventFlags` raw value,
    /// a `SessionModifiers` reading's `flags`.
    public let flags: UInt64
    /// When the change happened, in nanoseconds on the clock the machine has been up on.
    public let uptimeNanoseconds: UInt64

    public init(flags: UInt64, uptimeNanoseconds: UInt64) {
        self.flags = flags
        self.uptimeNanoseconds = uptimeNanoseconds
    }
}

/// One reading of the window server's session: its modifier flags as it gives them, and
/// whether the Fn key itself is down. The session sets the secondary-Fn bit
/// (`NX_SECONDARYFNMASK`) for the arrow, Home, End, Page Up/Down and Forward Delete keys too,
/// Fn held or not, so `flags` takes that bit from the Fn key's own state, read from the same
/// session like the rest, with no tally kept of its presses.
/// [LAW:one-source-of-truth] Both processes read the session through this: the input method
/// at each change it tells, and the app when it confirms what is still held.
public struct SessionModifiers: Equatable, Sendable, CustomStringConvertible {
    public let session: UInt64
    public let fnKeyDown: Bool

    public init(session: UInt64, fnKeyDown: Bool) {
        self.session = session
        self.fnKeyDown = fnKeyDown
    }

    public static func read() -> SessionModifiers {
        SessionModifiers(session: CGEventSource.flagsState(.combinedSessionState).rawValue,
                         fnKeyDown: CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Function)))
    }

    /// The modifiers held: the session's flags, with the secondary-Fn bit the Fn key's.
    public var flags: UInt64 {
        let fn = CGEventFlags.maskSecondaryFn.rawValue
        return session & ~fn | (fnKeyDown ? fn : 0)
    }

    /// [LAW:nothing-unseen] Both readings, and what was held when the Fn key's state and the
    /// session's bit disagree, so the log tells an arrow key taken for Fn from Fn unheard.
    public var description: String {
        "session 0x\(String(session, radix: 16)), Fn key \(fnKeyDown ? "down" : "up")"
            + (flags == session ? "" : ", held 0x\(String(flags, radix: 16))")
    }
}

/// The app's end of the hotkey port: the named port the input method tells each change of
/// the modifier keys to.
///
/// **Only this installation's input method is heard.** The name is one anyone can compute,
/// and a change heard from anyone else is a press anyone can fake, which opens the
/// microphone. So every message is checked against `senders` before its bytes are read, and
/// one that fails is told as `turnedAway` and never reaches `heard`. [LAW:single-enforcer]
///
/// Nothing is answered: the input method sends from the thread every key passes through, and
/// it waits for nothing there. A message that asked for an answer anyway has its reply right
/// released unanswered.
///
/// Held for as long as the app listens. Released, the name is free before the release
/// returns, because the app hosts it again straight away each time it rebuilds its hotkey;
/// so it is released off `queue`, which it waits for.
public final class ModifierPort {
    private let port: NamedPort

    deinit { port.close() }

    /// Something the port did that nobody asked it for, said so the log can say it.
    public enum Event: CustomStringConvertible {
        /// A message from a process `senders` does not admit.
        case turnedAway(pid: pid_t, because: PeerIdentity.NotAdmitted, required: PeerIdentity)
        /// A message from the input method that is not held modifiers.
        case notUnderstood(id: mach_msg_id_t, bytes: Int?)
        /// Taking a message off the port failed for a reason of the kernel's.
        case receiveFailed(kern_return_t)

        public var description: String {
            switch self {
            case let .turnedAway(pid, because, required):
                "ignored modifier keys told by pid \(pid): \(because), and only \(required) is heard"
            case let .notUnderstood(id, bytes):
                "the input method sent message \(id) of \(bytes.map { "\($0) bytes" } ?? "an unreadable shape"), which is not held modifiers"
            case .receiveFailed(let status):
                "a message could not be taken off the hotkey port: \(Mach.describe(status))"
            }
        }
    }

    /// Hosts the hotkey port, hearing the input method and nobody else.
    /// `heard` and `told` run on `queue`, one message at a time, in the order they were sent.
    public convenience init(
        queue: DispatchQueue,
        told: @escaping @Sendable (Event) -> Void, heard: @escaping @Sendable (HeldModifiers) -> Void
    ) throws(PortNotHosted) {
        let senders: PeerIdentity
        do throws(PeerIdentity.Unreadable) {
            senders = try .signedLikeThisProcess(identifier: AppIdentity.inputMethodBundleIdentifier)
        } catch { throw .noRequirement(error) }
        try self.init(portName: AppIdentity.hotkeyPortName, senders: senders, queue: queue, told: told, heard: heard)
    }

    /// Under a name and a requirement someone else chose, which is how a test hosts one
    /// without being the app. [LAW:decomposition]
    init(
        portName: String, senders: PeerIdentity, queue: DispatchQueue,
        told: @escaping @Sendable (Event) -> Void, heard: @escaping @Sendable (HeldModifiers) -> Void
    ) throws(PortNotHosted) {
        port = try NamedPort(name: portName, queue: queue, received: { message in
            message.discardReply()
            do throws(PeerIdentity.NotAdmitted) {
                try senders.admits(message.sender)
            } catch {
                told(.turnedAway(pid: message.sender.pid, because: error, required: senders))
                return
            }
            // [LAW:parse-dont-validate] The border: past it there are held modifiers, and
            // anything else is said by name rather than dropped. [LAW:no-silent-failure]
            guard message.id == Wire.modifiers, let held = message.payload.flatMap(Wire.heldModifiers(of:)) else {
                told(.notUnderstood(id: message.id, bytes: message.payload?.count))
                return
            }
            heard(held)
        }, failed: { told(.receiveFailed($0)) })
    }
}

/// The input method's end of the hotkey port: one message, sent and not waited on.
///
/// Called from the thread every key this source passes through is handled on, so it waits
/// for nothing: the app's queue is either taking messages or it is not. A change the app was
/// too busy to take is corrected by the next, since each carries the whole state, or - for a
/// release, which may have no next - by the app reading the session itself while a key is held.
///
/// Nothing asks who holds the name before telling it. What crosses is which modifier keys
/// are down, and the app is the one side that has something to protect - its microphone -
/// so it is the side that checks. [LAW:single-enforcer]
public struct ModifierSender: Sendable {
    private let portName: String

    /// How a message fared, said so the input method can log a change in it.
    public enum Told: Equatable, Sendable, CustomStringConvertible {
        case told
        /// No app is listening on the name: this installation's app is not running, or is
        /// hearing its hotkey some other way.
        case nobodyIsListening(port: String)
        /// The app is listening and did not take the message at once.
        case notTaken(port: String)
        case failed(port: String, status: kern_return_t)

        /// Whether this is something gone wrong rather than an ordinary state: nobody
        /// listening is how every app hearing its hotkey another way looks from here.
        public var isFault: Bool {
            switch self {
            case .told, .nobodyIsListening: false
            case .notTaken, .failed: true
            }
        }

        public var description: String {
            switch self {
            case .told: "the app hears the modifier keys"
            case .nobodyIsListening(let port): "nothing is listening on \(port), so the app does not hear the modifier keys from here"
            case .notTaken(let port): "the app on \(port) did not take a change of the modifier keys at once, so it missed that one"
            case let .failed(port, status): "a change of the modifier keys could not be sent to \(port): \(Mach.describe(status))"
            }
        }
    }

    public init() {
        self.init(portName: AppIdentity.hotkeyPortName)
    }

    init(portName: String) {
        self.portName = portName
    }

    public func tell(_ held: HeldModifiers) -> Told {
        var remote = mach_port_t()
        guard lt_bootstrap_look_up(portName, &remote) == KERN_SUCCESS else { return .nobodyIsListening(port: portName) }
        defer { mach_port_deallocate(mach_task_self_, remote) }
        let sent = Mach.send(
            Wire.modifiers(held), id: Wire.modifiers, to: remote, disposition: mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND),
            replyTo: Mach.noPort, timeout: .zero)
        return switch sent {
        case MACH_MSG_SUCCESS: .told
        // The app went away between the lookup and the send, which is the same fact as
        // finding nobody.
        case MACH_SEND_INVALID_DEST: .nobodyIsListening(port: portName)
        case MACH_SEND_TIMED_OUT: .notTaken(port: portName)
        default: .failed(port: portName, status: sent)
        }
    }
}
