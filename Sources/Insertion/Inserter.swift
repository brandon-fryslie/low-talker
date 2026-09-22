import Flavors
import Foundation

/// Something that puts text at the cursor and says what happened.
///
/// The seam low-input-method-s71.b26's executor consumes, and the reason it is a protocol
/// rather than the concrete channel below: a test puts a double on this side of it and
/// never starts a second process. [LAW:decomposition] Nothing here mentions ports, input
/// methods or macOS - the caller's question is "did these words land", and that question
/// outlives whatever carries it.
public protocol Inserter: Sendable {
    /// Inserts `text` at the cursor, or says why it did not.
    ///
    /// Throws `Unreachable` only when the question could not be carried at all. A refusal
    /// is an answer and comes back as one.
    func insert(_ text: String) throws -> InsertionAnswer
}

/// The app's end of the channel: one round trip to this flavor's input method.
///
/// Synchronous, with the wait bounded by the transport's own timeouts rather than by a
/// deadline this type keeps. `CFMessagePortSendRequest` is a send and a receive with a
/// timeout each, so the bound is where the waiting actually happens.
/// [LAW:no-ambient-temporal-coupling]
///
/// Nothing is retried. An input method that did not answer is one whose state nobody here
/// knows - it may have inserted the words and died before replying - and sending again
/// would be the one way to type the same sentence twice.
public struct InputMethodInserter: Inserter {
    private let portName: String
    private let timeout: Duration

    /// `flavor` says which installation's input method this reaches. No default, for the
    /// reason `HelperConnection` has none: both copies run at once, and a channel that
    /// guessed would put one installation's words in the other's window.
    public init(flavor: Flavor, timeout: Duration = .seconds(5)) {
        self.init(portName: flavor.inputMethodPortName, timeout: timeout)
    }

    /// Onto a port someone else named, which is how a test puts its own port on the far
    /// end without installing an input method. [LAW:decomposition]
    init(portName: String, timeout: Duration) {
        self.portName = portName
        self.timeout = timeout
    }

    public func insert(_ text: String) throws -> InsertionAnswer {
        // [LAW:parse-dont-validate] The boundary: past here there is a port or a thrown
        // reason, never a maybe-port that later code has to keep asking about.
        guard let port = CFMessagePortCreateRemote(nil, portName as CFString) else {
            throw Unreachable.nothingIsListening(port: portName)
        }
        var reply: Unmanaged<CFData>?
        let seconds = timeout.seconds
        let status = CFMessagePortSendRequest(
            port, 0, Wire.request(text) as CFData, seconds, seconds,
            CFRunLoopMode.defaultMode.rawValue, &reply
        )
        guard status == kCFMessagePortSuccess else {
            throw status == kCFMessagePortReceiveTimeout || status == kCFMessagePortSendTimeout
                ? Unreachable.answerDidNotArrive(port: portName, after: timeout)
                : Unreachable.sendFailed(port: portName, status: status)
        }
        let data = reply.map { $0.takeRetainedValue() as Data } ?? Data()
        guard let answer = Wire.answer(of: data) else {
            throw Unreachable.answerWasNotReadable(port: portName, bytes: data.count)
        }
        return answer
    }
}

extension Duration {
    /// As `CFMessagePortSendRequest` wants it. Whole seconds and the fraction, because
    /// dropping the fraction would silently round a sub-second timeout to none at all.
    var seconds: CFTimeInterval {
        CFTimeInterval(components.seconds) + CFTimeInterval(components.attoseconds) / 1e18
    }
}
