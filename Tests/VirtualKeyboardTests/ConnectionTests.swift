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

    /// A write that fails is the same loss as a stream that ends, found by the thread that
    /// asked rather than the one that reads: told once, thrown from the request that found
    /// it, and every later request fails by the same name. [LAW:single-enforcer]
    ///
    /// The write is made to fail by shutting this side's sending half, which makes the
    /// next write fail with EPIPE while the reader goes on reading. Not the daemon's
    /// receiving half: measured, a peer's SHUT_RD leaves this side's writes succeeding on
    /// XNU, so that would test nothing.
    @Test func aWriteThatFailsIsTheLossToldOnceAndThrownFromTheRequestThatFoundIt() throws {
        let fake = FakeDaemon()
        let lost = Lost()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, whenLost: lost.record)
        #expect(shutdown(fake.clientDescriptor, SHUT_WR) == 0)
        let failed = DaemonError.socket("write", EPIPE)
        #expect(throws: failed) { try connection.request(.keyboardInitialize, by: .now + .seconds(2)) }
        #expect(lost.await() == failed)
        #expect(throws: failed) { try connection.request(.keyboardReset, by: .now + .seconds(2)) }
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

    /// An answer to a request nobody waits on any more - it timed out and was forgotten -
    /// is dropped, and the next request is answered as its own.
    @Test func aLateAnswerToAForgottenRequestIsDroppedAndTheNextIsAnswered() throws {
        // Initialize is left unanswered; everything else is answered at once.
        let fake = FakeDaemon { frame, daemon in
            guard case .request(let id, let payload) = frame, requestSent(payload).request != DaemonConnection.Request.keyboardInitialize.rawValue else { return }
            try daemon.send(.response(id: id, payload: []))
        }
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor)
        #expect(throws: DaemonError.silent) { try connection.request(.keyboardInitialize, by: .now + .milliseconds(50)) }
        let forgotten = try #require(fake.received.compactMap { if case .request(let id, _) = $0 { id } else { nil } }.first)
        try fake.send(.response(id: forgotten, payload: []))
        #expect(throws: Never.self) { try connection.request(.keyboardReset, by: .now + .seconds(2)) }
    }

    /// A daemon that stops draining its socket without hanging up - and keeps talking, so
    /// its silence never shows on the reading side - stalls a write once the kernel's
    /// buffers are full. The write is bounded by the patience like a read, and past it the
    /// request ends in the same loss, rather than blocking the writer and, through the
    /// lock, every waiter, for good. [LAW:no-ambient-temporal-coupling]
    ///
    /// The frames are the largest this side sends, against 8 KB of send space and 8 KB of
    /// receive space on a local stream socket (`sysctl net.local.stream`): the first few
    /// are written and time out unanswered, and the one that finds the buffers full is the
    /// loss. Sixteen would be four times the buffers, so one of them stalls.
    @Test func aWriteThePeerStopsDrainingEndsAsSilenceWithinThePatience() throws {
        // Reads one frame, then talks without listening: a heartbeat every 50 ms for two
        // seconds, and not one more read. The loop ends early when the client has hung up.
        let fake = FakeDaemon { _, daemon in
            for _ in 0..<40 {
                do { try daemon.send(.control(.heartbeat, payload: [])) } catch { return }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        let lost = Lost()
        let connection = try DaemonConnection(fileDescriptor: fake.clientDescriptor, patience: .milliseconds(200), whenLost: lost.record)
        #expect(throws: DaemonError.silent) { try connection.request(.keyboardInitialize, by: .now + .milliseconds(50)) }

        let payload = [UInt8](repeating: 0, count: Frame.largestBody - 12)
        let ended = DispatchSemaphore(value: 0)
        let thrown = Lost()
        Thread {
            for _ in 0..<16 where lost.count == 0 {
                do { try connection.request(.postKeyboardInputReport, payload, by: .now + .milliseconds(50)) }
                catch let error as DaemonError { thrown.record(error) }
                catch { Issue.record("a request threw \(error), which is not the daemon's") }
            }
            ended.signal()
        }.start()
        #expect(ended.wait(timeout: .now() + .seconds(2)) == .success, "the stalled write did not end within 2 s")
        #expect(lost.await(within: .zero) == .silent)
        #expect(lost.count == 1)
        #expect(thrown.all.allSatisfy { $0 == .silent })
        #expect((2...16).contains(thrown.count), "\(thrown.count) frames were written before one stalled")
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

    var all: [DaemonError] {
        lock.lock(); defer { lock.unlock() }
        return errors
    }

    var count: Int { all.count }

    /// The first error, waited for within `limit`; a limit of zero reads what is there.
    func await(within limit: Duration = .seconds(2)) -> DaemonError? {
        let deadline = ContinuousClock.now + limit
        repeat {
            lock.lock(); let first = errors.first; lock.unlock()
            if let first { return first }
            Thread.sleep(forTimeInterval: 0.002)
        } while ContinuousClock.now < deadline
        return nil
    }
}
