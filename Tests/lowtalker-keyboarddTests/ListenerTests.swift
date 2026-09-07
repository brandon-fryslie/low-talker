import Foundation
import Keystrokes
import Testing
@testable import KeyboardService
@testable import lowtalker_keyboardd

/// The listener as a client meets it: the real `Listener` on an anonymous listener in this
/// process, with a requirement this process satisfies, and devices of the test's own
/// behind it. One client is admitted, a second is refused while the first holds the
/// devices, and the first going away releases everything and frees them.
/// [LAW:behavior-not-structure]
@Suite struct ListenerTests {
    /// The devices served: remember what they were asked, and say when they were released.
    private final class FakeDevices: NSObject, ServedDevices, @unchecked Sendable {
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

        func releaseAll(reply: @escaping (Error?) -> Void) { reply(nil) }
        func buttonDown(_ button: UInt8, reply: @escaping (Error?) -> Void) { reply(nil) }
        func releaseButtons(reply: @escaping (Error?) -> Void) { reply(nil) }
        func move(x: Int8, y: Int8, reply: @escaping (Error?) -> Void) { reply(nil) }
        func scroll(vertical: Int8, horizontal: Int8, reply: @escaping (Error?) -> Void) { reply(nil) }

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
        let devices: FakeDevices
    }

    private func serve() throws -> Served {
        let devices = FakeDevices()
        let delegate = Listener(devices: devices, callers: try CallerIdentity(requirement: try OwnProcess.requirement()))
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        return Served(listener: listener, delegate: delegate, devices: devices)
    }

    /// A client, with its connection alongside so the test can end it the way a client
    /// going away does.
    private func client(of served: Served) -> (helper: HelperConnection, connection: NSXPCConnection) {
        let connection = NSXPCConnection(listenerEndpoint: served.listener.endpoint)
        return (HelperConnection(connection: connection, replyTimeout: .seconds(20)), connection)
    }

    /// Runs `body` on a thread of the test's own and awaits what it returned or threw:
    /// `HelperConnection` blocks until the helper answers, and a wait on the cooperative
    /// pool starves the reply it is waiting for. [LAW:no-ambient-temporal-coupling]
    private func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread { continuation.resume(with: Result { try body() }) }.start()
        }
    }

    /// Whether a fresh client pressing `usage` was admitted; a refused connection is
    /// unreachable from the client's side.
    private func admitted(_ served: Served, pressing usage: Usage) async throws -> Bool {
        let keyboard = client(of: served).helper.keyboard
        do {
            try await blocking { try keyboard.down(usage) }
            return true
        } catch is HelperConnection.Unreachable {
            return false
        }
    }

    @Test func theFirstClientIsAdmittedAndASecondIsRefusedWhileItHolds() async throws {
        let served = try serve()
        let first = client(of: served)
        let keyboard = first.helper.keyboard
        try await blocking { try keyboard.down(.leftShift) }
        #expect(served.devices.asked == [Usage.leftShift.rawValue])
        #expect(try await admitted(served, pressing: .space) == false)
        #expect(served.devices.asked == [Usage.leftShift.rawValue])
        withExtendedLifetime((served, first)) {}
    }

    /// The first client going away releases everything, and the devices are then another
    /// client's. The release comes before the devices are let go, and the test can see
    /// only the first of the two, so the next client's admission is asked for until it
    /// comes or two seconds pass.
    @Test func aClientGoingAwayReleasesEverythingAndFreesTheDevices() async throws {
        let served = try serve()
        let first = client(of: served)
        let keyboard = first.helper.keyboard
        try await blocking { try keyboard.down(.leftShift) }
        first.connection.invalidate()
        #expect(served.devices.awaitRelease())
        #expect(served.devices.releasedBecause.first == "a client went away")

        let deadline = ContinuousClock.now + .seconds(2)
        var next = try await admitted(served, pressing: .space)
        while !next, ContinuousClock.now < deadline {
            next = try await admitted(served, pressing: .space)
        }
        #expect(next, "no client was admitted after the first went away")
        #expect(served.devices.asked == [Usage.leftShift.rawValue, Usage.space.rawValue])
        withExtendedLifetime((served, first)) {}
    }
}
