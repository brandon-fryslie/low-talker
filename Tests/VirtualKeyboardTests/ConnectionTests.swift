import Foundation
import Keystrokes
import Testing
@testable import VirtualKeyboard

/// What the connection does between requests, which is where a long-lived one spends
/// nearly all of its life. Measured on the daemon: it hangs up on a client that has sent
/// nothing for fifteen seconds, and answering its status pushes does not count as sending.
@Suite struct ConnectionTests {
    /// A heartbeat goes out on its own, with nobody asking anything. Timed against a short
    /// interval so the test watches for the behaviour rather than sleeping the daemon's
    /// three seconds. [LAW:behavior-not-structure]
    @Test func aHeartbeatGoesOutWhileNothingIsBeingAsked() throws {
        let fake = FakeDaemon()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, heartbeatEvery: .milliseconds(20))
        #expect(fake.awaitFrame(.control(.heartbeat, payload: [])))
        withExtendedLifetime(connection) {}
    }

    /// A status the daemon pushes while nothing is in flight is recorded and answered: the
    /// reading does not wait for a request to happen inside of.
    @Test func aStatusPushedBetweenRequestsIsRecordedAndAnswered() throws {
        let fake = FakeDaemon()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor)
        try fake.push([(.keyboardReady, true)])
        #expect(throws: Never.self) { try connection.awaitKeyboardReady(by: .now + .seconds(2)) }
        #expect(fake.awaitFrame(.response(id: 10_001, payload: [])))
    }

    /// The daemon going away is an event, told once to whoever holds the connection, and
    /// every request after it fails by the same name rather than by a broken pipe on the
    /// next write. [LAW:no-silent-failure]
    @Test func theDaemonHangingUpIsToldOnceAndFailsEveryLaterRequest() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let device = VirtualKeyboard(daemon: try DaemonConnection(fileDescriptor: fake.clientDescriptor, whenLost: lost.record), reportTimeout: .seconds(2))
        fake.hangUp()
        #expect(lost.await() == .closed)
        #expect(throws: DaemonError.closed) { try device.down(.leftShift) }
        #expect(throws: DaemonError.closed) { try device.releaseAll() }
        #expect(lost.count == 1)
    }

    /// A daemon that stops talking without hanging up - suspended, or wedged - is as gone
    /// as one that closed the stream, and is found out by its silence rather than waited
    /// on forever. [LAW:no-ambient-temporal-coupling]
    @Test func aDaemonThatSaysNothingForThePatienceIsLost() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, patience: .milliseconds(100), whenLost: lost.record)
        #expect(lost.await() == .silent)
        withExtendedLifetime(connection) {}
    }

    /// A daemon that stops mid-frame is the same silence, noticed in the middle of a read
    /// rather than between frames.
    @Test func aDaemonThatStopsMidFrameIsLost() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, patience: .milliseconds(100), whenLost: lost.record)
        try fake.sendRaw([0, 0])
        #expect(lost.await() == .silent)
        withExtendedLifetime(connection) {}
    }

    /// A version mismatch arrives on the frame that answers a request, and that request
    /// fails by its name: the answer does not count, because a driver built for another
    /// protocol did not do what was asked. [LAW:no-silent-failure]
    @Test func anAnswerCarryingAVersionMismatchFailsTheRequestItAnswers() throws {
        let fake = FakeDaemon { frame, daemon in
            if case .request(let id, _) = frame {
                try daemon.send(.response(id: id, payload: [DaemonConnection.Status.driverVersionMismatched.rawValue, 1]))
            }
        }
        let lost = Lost()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, whenLost: lost.record)
        #expect(throws: DaemonError.driverVersionMismatched) { try connection.request(.keyboardInitialize, by: .now + .seconds(2)) }
        #expect(lost.await() == .driverVersionMismatched)
    }

    /// This side hanging up is not the daemon's doing, and is not reported as it.
    @Test func hangingUpOurselvesTellsNobody() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        do {
            let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, whenLost: lost.record)
            withExtendedLifetime(connection) {}
        }
        // The fake's thread ends on the client's end of stream, which is the same event
        // the callback would fire on; once it has ended, the callback has had its chance.
        Thread.sleep(forTimeInterval: 0.05)
        #expect(lost.count == 0)
    }
}

/// What `whenLost` was told, readable from the test's thread.
private final class Lost: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [DaemonError] = []

    @Sendable func record(_ error: DaemonError) {
        lock.lock(); errors.append(error); lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return errors.count
    }

    func await(within limit: Duration = .seconds(2)) -> DaemonError? {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            lock.lock(); let first = errors.first; lock.unlock()
            if let first { return first }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return nil
    }
}
