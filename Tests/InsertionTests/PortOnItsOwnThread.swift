import Foundation
@testable import Insertion

/// A port hosted on a run loop of its own, which is how these tests stand in for the input
/// method process without starting one.
///
/// A thread and not this one, because the real port lives across a process boundary and a
/// port serviced by the sender's own run loop cannot show what that costs: a handler that
/// takes too long would hold the very loop that is supposed to notice it took too long, and
/// the timeout under test could never fire. [LAW:behavior-not-structure]
///
/// One type for both the real port and the raw one the failure cases need, because what
/// differs between them is which port gets hosted - a value, not a structure.
/// [LAW:one-type-per-behavior]
final class PortOnItsOwnThread {
    private let hosting: Hosting

    /// Returns once the port is answering, or throws what hosting it threw. Either way the
    /// caller never races its own setup. [LAW:no-ambient-temporal-coupling]
    init(host: @escaping @Sendable () throws -> AnyObject) throws {
        let hosting = Hosting()
        let ready = DispatchSemaphore(value: 0)
        Thread {
            let port: AnyObject
            do {
                port = try host()
            } catch {
                hosting.failed(error)
                ready.signal()
                return
            }
            let loop: CFRunLoop = CFRunLoopGetCurrent()
            hosting.began(on: loop)
            // Signalled from INSIDE the loop rather than before it, so that "ready" means
            // running and not merely built. `stop()` is `CFRunLoopStop`, which does nothing
            // to a loop that has not started yet; a caller that stopped in that window
            // would leave this thread entering `CFRunLoopRun()` for the rest of the suite,
            // holding the port name. [LAW:no-ambient-temporal-coupling]
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { ready.signal() }
            // The port is a local, so it lives exactly as long as the loop servicing it.
            withExtendedLifetime(port) { CFRunLoopRun() }
        }.start()
        ready.wait()
        try hosting.rethrow()
        self.hosting = hosting
    }

    func stop() { hosting.stop() }

    deinit { stop() }

    /// What the thread and its maker share, which is the whole of what crosses between
    /// them. [LAW:no-shared-mutable-globals]
    private final class Hosting: @unchecked Sendable {
        private let lock = NSLock()
        private var loop: CFRunLoop?
        private var failure: Error?

        func began(on loop: CFRunLoop) {
            lock.lock()
            self.loop = loop
            lock.unlock()
        }

        func failed(_ error: Error) {
            lock.lock()
            failure = error
            lock.unlock()
        }

        func rethrow() throws {
            lock.lock()
            defer { lock.unlock() }
            if let failure { throw failure }
        }

        /// Asks the hosting thread to leave its loop, which it does once it is not inside
        /// an answer - so a handler still running finishes before its port goes away.
        func stop() {
            lock.lock()
            let loop = self.loop
            self.loop = nil
            lock.unlock()
            loop.map(CFRunLoopStop)
        }
    }
}

extension PortOnItsOwnThread {
    /// The real port, answering as the input method would.
    static func insertion(name: String, answer: @escaping @Sendable (String) -> InsertionAnswer) throws -> PortOnItsOwnThread {
        try PortOnItsOwnThread { try InsertionPort(portName: name, answer: answer) }
    }

    /// A port that is not an `InsertionPort`: it answers whatever bytes a test hands it.
    static func raw(name: String, reply: @escaping @Sendable (Data) -> Data) throws -> PortOnItsOwnThread {
        try PortOnItsOwnThread { try RawPort(name: name, reply: reply) }
    }
}

/// A bare CFMessagePort, so a test can put an answer on the wire that no `InsertionPort`
/// would ever send.
private final class RawPort {
    private let held: Unmanaged<Replying>
    private let port: CFMessagePort

    struct CouldNotHost: Error {}

    init(name: String, reply: @escaping (Data) -> Data) throws {
        let held = Unmanaged.passRetained(Replying(reply: reply))
        var context = CFMessagePortContext(
            version: 0, info: held.toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: CFMessagePortCallBack = { _, _, data, info in
            let replying = Unmanaged<Replying>.fromOpaque(info!).takeUnretainedValue()
            return Unmanaged.passRetained(replying.reply(data.map { $0 as Data } ?? Data()) as CFData)
        }
        guard let port = CFMessagePortCreateLocal(nil, name as CFString, callback, &context, nil) else {
            held.release()
            throw CouldNotHost()
        }
        self.held = held
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMessagePortCreateRunLoopSource(nil, port, 0), .commonModes)
    }

    deinit {
        CFMessagePortInvalidate(port)
        held.release()
    }

    private final class Replying {
        let reply: (Data) -> Data
        init(reply: @escaping (Data) -> Data) { self.reply = reply }
    }
}

/// Runs `body` on a thread of the test's own and awaits what it returned or threw.
///
/// For the cases that send by hand rather than through `Inserter`'s awaited overload: a test
/// body runs on the cooperative pool, and a blocking send there holds one of its threads for
/// the whole wait. `HelperKeyboardTests` and `ListenerTests` each keep a copy of this for the
/// same reason and against the same measurement - four blocking calls held every thread of a
/// three-core runner and no other test ran. Three copies of five lines is one copy too many
/// twice over; unifying them is low-tests-ape's. [LAW:no-ambient-temporal-coupling]
func onAThreadOfItsOwn<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result { try body() }) }.start()
    }
}

/// A port name no other test, no repeat of this one, and no installed input method answers
/// on.
///
/// Unique per call and not per case, because `stop()` does not wait: a case whose far end is
/// still inside an answer when the case returns leaves its name held until that answer
/// finishes, and `#function` with `getpid()` are the same two values on the next pass through
/// the same case in the same process. A rerun would then be refused `NameIsTaken` by its own
/// previous run. [LAW:no-ambient-temporal-coupling]
func aPortNobodyElseUses(_ note: String = #function) -> String {
    "ai.promptctl.low-talker.test.insert.\(abs(note.hashValue)).\(getpid()).\(UUID().uuidString)"
}
