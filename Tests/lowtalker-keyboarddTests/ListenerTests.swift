import Foundation
import Keystrokes
import Testing
@testable import KeyboardService
@testable import lowtalker_keyboardd

/// The listener as a client meets it: the real `Listener` on an anonymous listener in this
/// process, with a requirement this process satisfies, and a keyboard of the test's own
/// behind it. One client is admitted, a second is refused while the first holds the
/// keyboard, and the first going away releases every key and frees it.
/// [LAW:behavior-not-structure]
@Suite struct ListenerTests {
    /// The keyboard served: remembers what it was asked, and says when it was released.
    private final class FakeKeyboard: NSObject, ServedKeyboard, @unchecked Sendable {
        private let lock = NSLock()
        private var usages: [UInt16] = []
        private var reasons: [String] = []
        private let released = DispatchSemaphore(value: 0)

        var asked: [UInt16] {
            lock.lock(); defer { lock.unlock() }
            return usages
        }

        var releasedBecause: [String] {
            lock.lock(); defer { lock.unlock() }
            return reasons
        }

        func down(usage: UInt16, reply: @escaping (Error?) -> Void) {
            lock.lock(); usages.append(usage); lock.unlock()
            reply(nil)
        }

        func releaseAll(reply: @escaping (Error?) -> Void) {
            reply(nil)
        }

        func releaseEverything(because reason: String) {
            lock.lock(); reasons.append(reason); lock.unlock()
            released.signal()
        }

        func awaitRelease() -> Bool {
            released.wait(timeout: .now() + .seconds(2)) == .success
        }
    }

    /// The far end as one thing a test holds: the listener holds its delegate weakly, so
    /// a delegate held by nothing is gone before the first connection.
    private struct Served {
        let listener: NSXPCListener
        let delegate: Listener
        let keyboard: FakeKeyboard
    }

    private func serve() throws -> Served {
        let keyboard = FakeKeyboard()
        let delegate = Listener(keyboard: keyboard, callers: try CallerIdentity(requirement: try OwnProcess.requirement()))
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        return Served(listener: listener, delegate: delegate, keyboard: keyboard)
    }

    /// A client, with its connection alongside so the test can end it the way a client
    /// going away does.
    private func client(of served: Served) -> (keyboard: HelperKeyboard, connection: NSXPCConnection) {
        let connection = NSXPCConnection(listenerEndpoint: served.listener.endpoint)
        return (HelperKeyboard(connection: connection, replyTimeout: .seconds(20)), connection)
    }

    /// Runs `body` on a thread of the test's own and awaits what it returned or threw:
    /// `HelperKeyboard` blocks until the helper answers, and a wait on the cooperative
    /// pool starves the reply it is waiting for. [LAW:no-ambient-temporal-coupling]
    private func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread { continuation.resume(with: Result { try body() }) }.start()
        }
    }

    /// Whether a fresh client pressing `usage` was admitted; a refused connection is
    /// unreachable from the client's side.
    private func admitted(_ served: Served, pressing usage: Usage) async throws -> Bool {
        let (keyboard, _) = client(of: served)
        do {
            try await blocking { try keyboard.down(usage) }
            return true
        } catch is HelperKeyboard.Unreachable {
            return false
        }
    }

    @Test func theFirstClientIsAdmittedAndASecondIsRefusedWhileItHolds() async throws {
        let served = try serve()
        let first = client(of: served)
        let keyboard = first.keyboard
        try await blocking { try keyboard.down(.leftShift) }
        #expect(served.keyboard.asked == [Usage.leftShift.rawValue])
        #expect(try await admitted(served, pressing: .space) == false)
        #expect(served.keyboard.asked == [Usage.leftShift.rawValue])
        withExtendedLifetime((served, first)) {}
    }

    /// The first client going away releases every key, and the keyboard is then another
    /// client's. The keys go up before the keyboard is let go, and the test can see only
    /// the first of the two, so the next client's admission is asked for until it comes
    /// or two seconds pass.
    @Test func aClientGoingAwayReleasesEveryKeyAndFreesTheKeyboard() async throws {
        let served = try serve()
        let first = client(of: served)
        let keyboard = first.keyboard
        try await blocking { try keyboard.down(.leftShift) }
        first.connection.invalidate()
        #expect(served.keyboard.awaitRelease())
        #expect(served.keyboard.releasedBecause.first == "a client went away")

        let deadline = ContinuousClock.now + .seconds(2)
        var next = try await admitted(served, pressing: .space)
        while !next, ContinuousClock.now < deadline {
            next = try await admitted(served, pressing: .space)
        }
        #expect(next, "no client was admitted after the first went away")
        #expect(served.keyboard.asked == [Usage.leftShift.rawValue, Usage.space.rawValue])
        withExtendedLifetime((served, first)) {}
    }
}
