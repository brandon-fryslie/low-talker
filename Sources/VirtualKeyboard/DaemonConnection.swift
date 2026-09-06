import Foundation

/// One connection to Karabiner-VirtualHIDDevice-Daemon over its Unix domain stream
/// socket. Every failure names what the daemon did or did not say. [LAW:no-silent-failure]
///
/// Why a daemon and not the driver: opening the driver extension's user client requires
/// `com.apple.developer.driverkit.userclient-access` naming
/// `org.pqrs.Karabiner-DriverKit-VirtualHIDDevice`, which Apple grants per application
/// identifier and which only pqrs's own daemon holds. Root does not help; measured, in the
/// 3ti.2 spike. So the daemon is the way in.
///
/// **The caller must be root.** The socket's directory is mode 0700 owned by root, so a
/// process that is not root cannot see the socket at all. That is stated here once and
/// never re-checked inland: a privilege this type cannot acquire is not a condition for it
/// to keep testing. [LAW:no-defensive-null-guards]
final class DaemonConnection {
    static let socketPath = "/Library/Application Support/org.pqrs/tmp/rootonly/karabiner_virtual_hid_device_service.sock"
    /// The version this side speaks, from `virtual_hid_device_service/client.hpp`. Two
    /// bytes, and native-endian unlike everything around it - the framing is big-endian
    /// and the report inside is little-endian, and none of the three announces itself.
    static let clientProtocolVersion: UInt16 = 7

    /// The request table, by index, from `virtual_hid_device_service/request.hpp`.
    enum Request: UInt8 {
        case keyboardInitialize = 0
        case keyboardTerminate = 1
        case keyboardReset = 2
        case postKeyboardInputReport = 6
    }

    /// The status table, by index, from `virtual_hid_device_service/response.hpp`.
    enum Status: UInt8 {
        case none = 0
        case driverActivated = 1
        case driverConnected = 2
        case driverVersionMismatched = 3
        case keyboardReady = 4
        case pointingReady = 5
    }

    private let socket: Int32
    private var nextRequestID: UInt64 = 1
    /// The daemon's latest word on each status it has ever sent.
    private(set) var status: [Status: Bool] = [:]

    /// Connects to the daemon at the path above.
    convenience init() throws {
        guard FileManager.default.fileExists(atPath: Self.socketPath) else { throw DaemonError.noSocket }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DaemonError.socket("socket", errno) }
        self.init(fileDescriptor: descriptor)
        try configure()
        try connectToDaemon()
    }

    /// A connection over a descriptor someone else opened. This is the seam that makes
    /// the wire protocol testable: a `socketpair` puts a fake daemon on the other end, so
    /// the framing, the deadline reads and the request/response matching are exercised
    /// over a real socket rather than mocked away. [LAW:decomposition] The protocol and
    /// the pipe it runs over are two things, and only one of them needs root.
    init(fileDescriptor: Int32) {
        socket = fileDescriptor
    }

    /// The one place the descriptor closes. [LAW:single-enforcer] Every stored property is
    /// set by the initializer's first line, so an initializer that throws past that point
    /// still deallocates the instance and still runs this; an explicit close in a throwing
    /// branch would close the same descriptor twice, and the number it names is free to
    /// have been handed to something else by then.
    deinit {
        close(socket)
    }

    private func configure() throws {
        var noSignal: Int32 = 1
        // [LAW:no-silent-failure] This is the only thing standing between a write to a
        // closed socket and SIGPIPE ending the process without a word, so a failure to set
        // it is reported rather than assumed.
        guard setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw DaemonError.socket("setsockopt(SO_NOSIGPIPE)", errno)
        }
    }

    private func connectToDaemon() throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(Self.socketPath.utf8CString)
        precondition(path.count <= MemoryLayout.size(ofValue: address.sun_path), "the socket path outgrew sun_path")
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.map { UInt8(bitPattern: $0) }) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw DaemonError.socket("connect", errno) }
    }

    // MARK: - Requests

    /// Sends a request and waits for the daemon's answer to it. Every request is answered,
    /// including a posted report, so waiting on the answer is real flow control rather
    /// than a sleep guessed at. [LAW:no-ambient-temporal-coupling]
    func request(_ request: Request, _ payload: [UInt8] = [], by deadline: ContinuousClock.Instant) throws {
        let id = nextRequestID
        nextRequestID += 1
        let version = Self.clientProtocolVersion
        try write(Frame.request(id: id, payload: [UInt8(version & 0xff), UInt8(version >> 8), request.rawValue] + payload).bytes)
        while true {
            let frame = try readFrame(by: deadline)
            try handle(frame)
            if case .response(let answered, _) = frame, answered == id { return }
        }
    }

    /// Reads frames until the daemon says the keyboard is ready, and says when it first
    /// answered at all and when it said so. The wait is on the daemon's word, never a
    /// sleep - but note what the word costs: the daemon asks the driver once a second, so
    /// readiness is *discovered* on the next tick rather than when it happened, and this
    /// takes up to a second however fast the device really was. That is why a connection
    /// is meant to be held open rather than made per insert.
    func awaitKeyboardReady(by deadline: ContinuousClock.Instant) throws {
        while status[.keyboardReady] != true {
            try handle(try readFrame(by: deadline))
        }
    }

    /// What every frame means to this side: a pushed status is recorded and answered with
    /// an empty response, as pqrs's own client does; a health check is answered; a
    /// response's status pairs are recorded.
    private func handle(_ frame: Frame) throws {
        switch frame {
        case .control(.healthCheck, _):
            try write(Frame.control(.healthCheckResponse, payload: []).bytes)
        case .control:
            break
        case .request(let id, let payload):
            try record(payload)
            try write(Frame.response(id: id, payload: []).bytes)
        case .response(_, let payload):
            try record(payload)
        }
        // [LAW:single-enforcer] Version skew is a hard failure wherever it arrives, not a
        // note on the way past. A driver built for another protocol accepts reports and
        // then does something other than what they say, so there is no degraded mode to
        // continue into - and enforcing it on every frame means no later wait can block
        // on an answer that skew has already made impossible.
        guard status[.driverVersionMismatched] != true else { throw DaemonError.driverVersionMismatched }
    }

    /// The daemon's status payload, decoded: pairs of (status, value). Pure, and separate
    /// from recording for the reason the framing is - a transposed pair records the wrong
    /// status as true and nothing about that looks wrong at runtime. [LAW:decomposition]
    static func statusPairs(_ pairs: [UInt8]) throws -> [(Status, Bool)] {
        guard pairs.count % 2 == 0 else { throw DaemonError.malformed("a status payload of \(pairs.count) bytes, which is not pairs") }
        return try stride(from: 0, to: pairs.count, by: 2).map { index in
            guard let status = Status(rawValue: pairs[index]) else { throw DaemonError.malformed("status \(pairs[index]), which this was not written for") }
            return (status, pairs[index + 1] != 0)
        }
    }

    private func record(_ pairs: [UInt8]) throws {
        for (status, value) in try Self.statusPairs(pairs) {
            self.status[status] = value
        }
    }

    // MARK: - The socket

    private func readFrame(by deadline: ContinuousClock.Instant) throws -> Frame {
        let length = try Frame.bodyLength(header: read(4, by: deadline))
        return try Frame.decode(body: read(length, by: deadline))
    }

    /// EINTR says the call did not happen and must be made again, which is the opposite of
    /// a failure - and reporting a non-failure as one is the same lie as the reverse.
    /// [LAW:no-silent-failure] A signal delivered during a run is enough to trip it.
    private static func uninterrupted(_ call: () -> Int) -> Int {
        while true {
            let result = call()
            guard result < 0, errno == EINTR else { return result }
        }
    }

    private func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = Self.uninterrupted { bytes[offset...].withUnsafeBytes { Darwin.write(socket, $0.baseAddress, $0.count) } }
            guard written > 0 else { throw DaemonError.socket("write", errno) }
            offset += written
        }
    }

    private func read(_ count: Int, by deadline: ContinuousClock.Instant) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw DaemonError.silent }
            var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            let readable = poll(&descriptor, 1, Int32(remaining.components.seconds * 1_000 + remaining.components.attoseconds / 1_000_000_000_000_000))
            // Around the loop rather than retried in place, so the deadline is consulted
            // again and poll is given the time that is actually left instead of the whole
            // budget over: a signal must not extend the wait it interrupted.
            if readable < 0, errno == EINTR { continue }
            guard readable >= 0 else { throw DaemonError.socket("poll", errno) }
            guard readable > 0 else { throw DaemonError.silent }
            let got = Self.uninterrupted { bytes[offset...].withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress, $0.count) } }
            guard got > 0 else { throw got == 0 ? DaemonError.closed : DaemonError.socket("read", errno) }
            offset += got
        }
        return bytes
    }
}

public enum DaemonError: Error, CustomStringConvertible, Equatable {
    case noSocket
    case socket(String, Int32)
    case silent
    case closed
    case malformed(String)
    case driverVersionMismatched

    public var description: String {
        switch self {
        case .noSocket:
            "no socket at \(DaemonConnection.socketPath); Karabiner-VirtualHIDDevice-Daemon is not running, and only root can see it when it is"
        case .socket(let call, let code):
            "\(call) on the daemon's socket failed: \(String(cString: strerror(code))) (\(code))"
        case .silent:
            "the daemon did not answer in time"
        case .closed:
            "the daemon closed the connection"
        case .malformed(let what):
            "the daemon sent \(what)"
        case .driverVersionMismatched:
            "the daemon reports the driver's version is not the one it was built for"
        }
    }
}
