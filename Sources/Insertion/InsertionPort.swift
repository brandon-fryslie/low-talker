import Darwin
import Flavors
import Foundation
import DarwinCalls

/// The input method's end of the channel: the named port the app sends to.
///
/// [LAW:effects-at-boundaries] Hosting the port, checking who sent each request and
/// decoding its bytes is all this does. What to do with the text is the closure's, and the
/// closure is where the text input system lives - so the half that knows about macOS
/// clients knows nothing about ports, and this half knows nothing about clients.
///
/// **Only this installation's app is answered.** The name is derived from the public bundle
/// identifier, so any process running as the person can compute it, and a request answered
/// without asking who sent it is text typed into the front window for anyone, with no grant
/// at all. So every request is checked against `senders` before its bytes are read, and one
/// that fails is answered `senderIsNotThisInstallationsApp` and told to `turnedAway` - the
/// insert closure never sees it. [LAW:single-enforcer]
///
/// Both closures run on `queue`, one request at a time. That is the whole of the
/// concurrency story here: host it on the queue the thing it inserts into lives on, and
/// the two never race. [LAW:no-ambient-temporal-coupling]
///
/// Held for the life of the process by whoever makes it. Released, the port closes and the
/// app's next request finds nothing listening; a request already being answered finishes
/// first, because the port is only taken down once the queue is out of it.
public final class InsertionPort {
    private let source: DispatchSourceMachReceive

    /// The port was not published under its name.
    public enum NotHosted: Error, CustomStringConvertible {
        /// Someone is already answering on this name: another copy of this input method in
        /// another process, or another `InsertionPort` in this one.
        case nameIsTaken(String)
        case notRegistered(String, kern_return_t)
        case noPort(kern_return_t)
        case noRequirement(PeerIdentity.Unreadable)

        public var description: String {
            switch self {
            case .nameIsTaken(let name): "no port could be hosted on \(name); something is already answering there"
            case .notRegistered(let name, let status): "no port could be hosted on \(name): bootstrap status \(status)"
            case .noPort(let status): "no Mach port could be allocated: \(Mach.describe(status))"
            case .noRequirement(let failure): "nobody could be admitted to the insert port, because this process cannot say who signed it: \(failure)"
            }
        }
    }

    /// Something the port did that nobody asked it for, said so the log can say it.
    public enum Event: CustomStringConvertible {
        /// A request from a process `senders` does not admit, answered with a refusal.
        case turnedAway(pid: pid_t, because: PeerIdentity.NotAdmitted, required: PeerIdentity)
        /// An answer that could not be delivered: the sender is gone, or asked in a shape
        /// that leaves nowhere to answer.
        case answerNotDelivered(kern_return_t)
        /// Taking a request off the port failed for a reason of the kernel's.
        case receiveFailed(kern_return_t)

        public var description: String {
            switch self {
            case let .turnedAway(pid, because, required):
                "refused an insert from pid \(pid): \(because), and only \(required) may insert"
            case .answerNotDelivered(let status):
                "an answer could not be delivered: \(Mach.describe(status))"
            case .receiveFailed(let status):
                "a request could not be taken off the port: \(Mach.describe(status))"
            }
        }
    }

    /// Hosts this flavor's insert port, admitting this flavor's app and nobody else.
    public convenience init(
        flavor: Flavor, queue: DispatchQueue,
        told: @escaping (Event) -> Void, answer: @escaping (String) -> InsertionAnswer
    ) throws(NotHosted) {
        let senders: PeerIdentity
        do throws(PeerIdentity.Unreadable) { senders = try .signedLikeThisProcess(identifier: flavor.bundleIdentifier) } catch { throw .noRequirement(error) }
        try self.init(portName: flavor.inputMethodPortName, senders: senders, queue: queue, told: told, answer: answer)
    }

    /// Under a name and a requirement someone else chose, which is how a test hosts one
    /// without being an input method. [LAW:decomposition]
    convenience init(
        portName: String, senders: PeerIdentity, queue: DispatchQueue,
        told: @escaping (Event) -> Void, answer: @escaping (String) -> InsertionAnswer
    ) throws(NotHosted) {
        try self.init(portName: portName, queue: queue, told: told) { request in
            do throws(PeerIdentity.NotAdmitted) {
                try senders.admits(request.sender)
            } catch {
                told(.turnedAway(pid: request.sender.pid, because: error, required: senders))
                return Wire.answer(.refused(.senderIsNotThisInstallationsApp))
            }
            // The greeting is answered empty: the sender has been admitted, and that is all
            // it asked. [LAW:dataflow-not-control-flow] The id is the wire's own
            // discriminator, and these are its two values.
            guard request.id != Wire.greeting else { return Data() }
            // Bytes that are not text are answered, never dropped: a sender that hears
            // nothing waits out its timeout and learns nothing. [LAW:no-silent-failure]
            let text = request.payload.flatMap(Wire.text(of:))
            return Wire.answer(text.map(answer) ?? .refused(.requestWasNotText))
        }
    }

    /// A port that answers each message with whatever `respond` makes of it - the channel
    /// with nobody checked, which only the initializer above and the suite's hand-made far
    /// ends build on.
    init(portName: String, queue: DispatchQueue, told: @escaping (Event) -> Void, respond: @escaping (Mach.Received) -> Data) throws(NotHosted) {
        let right: ReceiveRight
        do throws(ReceiveRight.NotAllocated) { right = try ReceiveRight(sendable: true) } catch { throw .noPort(error.status) }
        let registered = lt_bootstrap_register(portName, right.port)
        guard registered == KERN_SUCCESS else {
            throw registered == BOOTSTRAP_NAME_IN_USE ? .nameIsTaken(portName) : .notRegistered(portName, registered)
        }
        source = DispatchSource.makeMachReceiveSource(port: right.port, queue: queue)
        // Every message waiting is taken each time the source fires, so a burst is not left
        // queued behind an event that has already been handled.
        source.setEventHandler {
            while true {
                switch Mach.receive(on: right.port, timeout: Duration.zero) {
                case .received(let request):
                    let sent = request.answer(respond(request))
                    if sent != MACH_MSG_SUCCESS { told(.answerNotDelivered(sent)) }
                case .failed(MACH_RCV_TIMED_OUT):
                    return
                case .failed(let status):
                    told(.receiveFailed(status))
                    return
                }
            }
        }
        // The right goes with the source, after the last handler has returned: the name is
        // withdrawn by the same step that stops anything answering on it.
        source.setCancelHandler { withExtendedLifetime(right) {} }
        source.activate()
    }

    deinit { source.cancel() }
}
