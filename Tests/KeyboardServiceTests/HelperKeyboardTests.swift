import Foundation
import Keystrokes
import Testing
@testable import KeyboardService

/// The client's side of the privilege seam, driven against a service of the test's own
/// on the far end of a real XPC connection: an anonymous listener in this process, so
/// what is exercised is the round trip and every way it ends, with nothing mocked but
/// who answers. [LAW:behavior-not-structure]
@Suite struct HelperKeyboardTests {
    /// What the service on the far end does with a call. One type, three behaviours as
    /// values. [LAW:one-type-per-behavior]
    enum Answer: Sendable {
        case acknowledge
        case refuse(domain: String, code: Int)
        case never
    }

    /// The far end: a service that answers as told, and remembers what it was asked.
    private final class Service: NSObject, KeyboardService, NSXPCListenerDelegate, @unchecked Sendable {
        private let answer: Answer
        private let lock = NSLock()
        private var usages: [UInt16] = []
        /// Replies never given, held so that a reply that was dropped rather than
        /// withheld cannot pass as the same thing.
        private var withheld: [(Error?) -> Void] = []

        init(_ answer: Answer) { self.answer = answer }

        var asked: [UInt16] {
            lock.lock(); defer { lock.unlock() }
            return usages
        }

        private func respond(_ reply: @escaping (Error?) -> Void) {
            switch answer {
            case .acknowledge:
                reply(nil)
            case .refuse(let domain, let code):
                reply(NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: "refused by the fake"]))
            case .never:
                lock.lock(); withheld.append(reply); lock.unlock()
            }
        }

        func down(usage: UInt16, reply: @escaping (Error?) -> Void) {
            lock.lock(); usages.append(usage); lock.unlock()
            respond(reply)
        }

        func releaseAll(reply: @escaping (Error?) -> Void) {
            respond(reply)
        }

        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface = NSXPCInterface(with: KeyboardService.self)
            connection.exportedObject = self
            connection.resume()
            return true
        }
    }

    /// The far end as one thing a test holds: the listener holds its delegate weakly, so
    /// a service held by nothing is gone before the first call, and the call fails as a
    /// connection failure whatever the test meant to try. [LAW:types-are-the-program]
    private struct FarEnd {
        let listener: NSXPCListener
        let service: Service
    }

    private func keyboard(_ answer: Answer, replyTimeout: Duration = .seconds(2)) -> (HelperKeyboard, FarEnd) {
        let service = Service(answer)
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        return (HelperKeyboard(connection: connection, replyTimeout: replyTimeout), FarEnd(listener: listener, service: service))
    }

    @Test func anAcknowledgedKeyGoesDownAndTheCallReturns() throws {
        let (keyboard, far) = keyboard(.acknowledge)
        try keyboard.down(.leftShift)
        try keyboard.releaseAll()
        #expect(far.service.asked == [Usage.leftShift.rawValue])
    }

    /// The helper's refusal reaches the caller as the error the helper sent, not as a
    /// connection failure. [LAW:no-silent-failure]
    @Test func theHelpersRefusalIsThrown() throws {
        let (keyboard, far) = keyboard(.refuse(domain: "fake", code: 7))
        let refusal = #expect(throws: NSError.self) { try keyboard.down(.space) }
        #expect(refusal?.domain == "fake")
        #expect(refusal?.code == 7)
        withExtendedLifetime(far) {}
    }

    /// A service that is gone is unreachable, said on the first call.
    @Test func aServiceThatWentAwayIsUnreachable() throws {
        let (keyboard, far) = keyboard(.acknowledge)
        far.listener.invalidate()
        #expect(throws: HelperKeyboard.Unreachable.self) { try keyboard.down(.space) }
    }

    /// A service that neither answers nor hangs up is unreachable at the deadline, rather
    /// than a caller blocked for good. [LAW:no-ambient-temporal-coupling]
    @Test func aServiceThatNeverAnswersIsUnreachableAtTheDeadline() throws {
        let (keyboard, far) = keyboard(.never, replyTimeout: .milliseconds(200))
        let began = ContinuousClock.now
        #expect(throws: HelperKeyboard.Unreachable.self) { try keyboard.down(.space) }
        #expect(ContinuousClock.now - began >= .milliseconds(200))
        // Held to the deadline: a far end gone early is unreachable for the wrong reason,
        // and a test that cannot tell the two apart proves nothing.
        withExtendedLifetime(far) {}
    }
}
