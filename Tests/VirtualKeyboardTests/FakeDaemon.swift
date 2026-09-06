import Foundation
import Testing
@testable import VirtualKeyboard

/// Karabiner-VirtualHIDDevice-Daemon, faked at the only place worth faking it: the far end
/// of a real socket, speaking the real framing.
///
/// A socketpair rather than a stubbed protocol, because what these tests are for is the
/// bytes - the frame length that is big-endian while the usages inside it are little, the
/// eight-byte id, the three uint64 parameters - and a stub of the protocol would agree
/// with whatever the code under test believed. Everything below the wire is real: the
/// client's own poll loop, its deadline, its request/response matching, its answers to
/// what the daemon pushes. What is fake is only who is on the other end.
final class FakeDaemon: @unchecked Sendable {
    /// The descriptor to hand `DaemonConnection`, which is why that seam exists.
    let clientDescriptor: Int32

    private let descriptor: Int32
    private let lock = NSLock()
    private var log: [Frame] = []
    private var pushID: UInt64 = 10_000

    /// `handling` runs on the daemon's own thread for every frame the client sends. The
    /// default answers each request with an empty response, which is what the daemon does
    /// for a posted report.
    init(handling: (@Sendable (Frame, FakeDaemon) throws -> Void)? = nil) {
        var pair: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0, "socketpair")
        clientDescriptor = pair[0]
        descriptor = pair[1]
        // Both halves of the pair refuse SIGPIPE by the same rule the client keeps: the
        // peer closing while this thread is mid-write would otherwise end the whole test
        // binary rather than fail one test. [LAW:single-enforcer]
        try! refuseSIGPIPE(descriptor)
        let answer: @Sendable (Frame, FakeDaemon) throws -> Void = handling ?? { frame, daemon in
            if case .request(let id, _) = frame { try daemon.send(.response(id: id, payload: [])) }
        }
        // The thread ends when the client closes its end, which every test does when its
        // `DaemonConnection` deallocates. There is deliberately no other stop: the loop
        // calls methods on `self`, so `deinit` cannot run while it is blocked in a read,
        // and a flag saying otherwise would be a stop path that cannot fire.
        let thread = Thread { [self] in
            while true {
                do {
                    let frame = try readFrame()
                    lock.lock(); log.append(frame); lock.unlock()
                    try answer(frame, self)
                } catch is Closed {
                    break
                } catch {
                    // The framing is what this suite exists to check, so a frame this
                    // cannot decode is the finding, not a detail to swallow: dropped, it
                    // reaches the test as an unrelated timeout on the client's next read.
                    // [LAW:no-silent-failure]
                    Issue.record("the fake daemon stopped: \(error)")
                    break
                }
            }
        }
        thread.stackSize = 1 << 20
        thread.start()
    }

    deinit {
        close(descriptor)
    }

    /// Every frame the client has sent, in order.
    var received: [Frame] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    /// Waits for a frame the client sends without waiting on anything itself - its answer
    /// to a health check, say. Every other frame is logged before the response the client
    /// is blocked on, so only these need waiting for; asserting on them straight after the
    /// call under test returns is a race, and one that passes most of the time.
    func awaitFrame(_ wanted: Frame, within limit: Duration = .seconds(2)) -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if received.contains(wanted) { return true }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return received.contains(wanted)
    }

    /// The payload of each request the client sent, which is where the version, the
    /// request byte and the request's own bytes live.
    var requestPayloads: [[UInt8]] {
        received.compactMap { if case .request(_, let payload) = $0 { payload } else { nil } }
    }

    func send(_ frame: Frame) throws {
        try sendRaw(frame.bytes)
    }

    /// A status push, which the daemon sends as a request of its own and the client is
    /// expected to answer.
    func push(_ statuses: [(DaemonConnection.Status, Bool)]) throws {
        lock.lock(); pushID += 1; let id = pushID; lock.unlock()
        try send(.request(id: id, payload: statuses.flatMap { [$0.0.rawValue, $0.1 ? 1 : 0] }))
    }

    /// Raw bytes, for the cases that are not well-formed frames at all.
    func sendRaw(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = uninterrupted { bytes[offset...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) } }
            guard written > 0 else { throw Failed(what: "write") }
            offset += written
        }
    }

    private func readFrame() throws -> Frame {
        let length = try Frame.bodyLength(header: read(4))
        return try Frame.decode(body: read(length))
    }

    private func read(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let got = uninterrupted { bytes[offset...].withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) } }
            guard got != 0 else { throw Closed() }
            guard got > 0 else { throw Failed(what: "read") }
            offset += got
        }
        return bytes
    }

    /// The client hung up. How the thread is meant to end, so it is its own type rather
    /// than a failure the loop has to recognise by its message. [LAW:types-are-the-program]
    struct Closed: Error {}
    struct Failed: Error { let what: String }
}

/// The request byte and payload the client actually sent, unwrapped from the two-byte
/// client protocol version in front of them.
func requestSent(_ payload: [UInt8]) -> (version: UInt16, request: UInt8, bytes: [UInt8]) {
    (UInt16(payload[0]) | UInt16(payload[1]) << 8, payload[2], Array(payload.dropFirst(3)))
}
