import Foundation
import Keystrokes
import Pointing
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
    private final class Service: NSObject, HelperService, NSXPCListenerDelegate, @unchecked Sendable {
        private let answer: Answer
        private let lock = NSLock()
        private var usages: [UInt16] = []
        private var pointing: [String] = []
        /// Replies never given, held so that a reply that was dropped rather than
        /// withheld cannot pass as the same thing.
        private var withheld: [(Error?) -> Void] = []

        init(_ answer: Answer) { self.answer = answer }

        var asked: [UInt16] {
            lock.lock(); defer { lock.unlock() }
            return usages
        }

        /// Every mouse call, in the wire's own integers.
        var pointed: [String] {
            lock.lock(); defer { lock.unlock() }
            return pointing
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

        private func note(_ what: String, _ reply: @escaping (Error?) -> Void) {
            lock.lock(); pointing.append(what); lock.unlock()
            respond(reply)
        }

        func down(usage: UInt16, reply: @escaping (Error?) -> Void) {
            lock.lock(); usages.append(usage); lock.unlock()
            respond(reply)
        }

        func releaseAll(reply: @escaping (Error?) -> Void) {
            respond(reply)
        }

        func buttonDown(_ button: UInt8, reply: @escaping (Error?) -> Void) { note("button \(button)", reply) }
        func releaseButtons(reply: @escaping (Error?) -> Void) { note("release", reply) }
        func move(x: Int8, y: Int8, reply: @escaping (Error?) -> Void) { note("move \(x) \(y)", reply) }
        func scroll(vertical: Int8, horizontal: Int8, reply: @escaping (Error?) -> Void) { note("scroll \(vertical) \(horizontal)", reply) }

        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface = NSXPCInterface(with: HelperService.self)
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

    /// The bound ends a test whose far end is broken; it measures nothing, so it sits far
    /// above any round trip. [LAW:no-ambient-temporal-coupling]
    private func helper(_ answer: Answer, replyTimeout: Duration = .seconds(20)) -> (HelperConnection, FarEnd) {
        let service = Service(answer)
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        return (HelperConnection(connection: connection, replyTimeout: replyTimeout), FarEnd(listener: listener, service: service))
    }

    /// Runs `body` on a thread of the test's own and awaits what it returned or threw.
    ///
    /// `HelperConnection` blocks the thread it is called on until the helper answers,
    /// which is its contract. A test body runs on the cooperative pool, whose width is the
    /// machine's core count, and a call that blocks there holds one of its threads for
    /// the whole wait: measured on the three-core CI runner, four such calls held every
    /// thread, no other test ran, the far end's own reply was never delivered, and the
    /// whole run ended when the deadlines did. The wait belongs on a thread that nothing
    /// else is scheduled on. [LAW:no-ambient-temporal-coupling]
    private func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread { continuation.resume(with: Result { try body() }) }.start()
        }
    }

    @Test func anAcknowledgedKeyGoesDownAndTheCallReturns() async throws {
        let (helper, far) = helper(.acknowledge)
        let keyboard = helper.keyboard
        try await blocking {
            try keyboard.down(.leftShift)
            try keyboard.releaseAll()
        }
        #expect(far.service.asked == [Usage.leftShift.rawValue])
    }

    /// The mouse's four acts cross the same connection as the keyboard's, each as the
    /// wire's own integers: a button by number, a count by its signed byte.
    @Test func theMouseRidesTheSameConnectionAsTheKeyboard() async throws {
        let (helper, far) = helper(.acknowledge)
        let mouse = helper.mouse
        try await blocking {
            try mouse.down(.left)
            try mouse.move(by: Move(x: Count(clamping: -3), y: Count(clamping: 127)))
            try mouse.scroll(by: Scroll(vertical: Count(clamping: 2), horizontal: Count(clamping: -1)))
            try mouse.releaseAll()
        }
        #expect(far.service.pointed == ["button 1", "move -3 127", "scroll 2 -1", "release"])
    }

    /// The helper's refusal reaches the caller as the error the helper sent, not as a
    /// connection failure. [LAW:no-silent-failure]
    @Test func theHelpersRefusalIsThrown() async throws {
        let (helper, far) = helper(.refuse(domain: "fake", code: 7))
        let keyboard = helper.keyboard
        let refusal = await #expect(throws: NSError.self) { try await blocking { try keyboard.down(.space) } }
        // The error itself when it is not the fake's, so a connection failure in its place
        // is read by its reason and not just by its domain.
        let heard = Comment(rawValue: refusal.map { "\($0 as Error)" } ?? "nothing was thrown")
        #expect(refusal?.domain == "fake", heard)
        #expect(refusal?.code == 7, heard)
        withExtendedLifetime(far) {}
    }

    /// A service that is gone is unreachable, said on the first call.
    @Test func aServiceThatWentAwayIsUnreachable() async throws {
        let (helper, far) = helper(.acknowledge)
        far.listener.invalidate()
        let keyboard = helper.keyboard
        await #expect(throws: HelperConnection.Unreachable.self) { try await blocking { try keyboard.down(.space) } }
    }

    /// A service that neither answers nor hangs up is unreachable at the deadline, rather
    /// than a caller blocked for good. [LAW:no-ambient-temporal-coupling]
    @Test func aServiceThatNeverAnswersIsUnreachableAtTheDeadline() async throws {
        let (helper, far) = helper(.never, replyTimeout: .milliseconds(200))
        let keyboard = helper.keyboard
        let began = ContinuousClock.now
        await #expect(throws: HelperConnection.Unreachable.self) { try await blocking { try keyboard.down(.space) } }
        #expect(ContinuousClock.now - began >= .milliseconds(200))
        // Held to the deadline: a far end gone early is unreachable for the wrong reason,
        // and a test that cannot tell the two apart proves nothing.
        withExtendedLifetime(far) {}
    }
}
