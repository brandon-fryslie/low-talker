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
///
/// **The socket is read by one thread for the life of the connection.** The daemon talks
/// when nobody has asked it anything - a heartbeat every three seconds, a health check
/// now and then, a status push when the driver changes state - and it hangs up on a
/// client that has said nothing for fifteen seconds, measured on this Mac. A connection
/// read only while a request was in flight went quiet between inserts and was found dead
/// by the next write. So the reading is not part of asking; it is a lifecycle with its own
/// owner, and asking is writing a request and waiting to be told the answer arrived.
/// [LAW:no-ambient-temporal-coupling]
final class DaemonConnection {
    static let socketPath = "/Library/Application Support/org.pqrs/tmp/rootonly/karabiner_virtual_hid_device_service.sock"
    /// The version this side speaks, from `virtual_hid_device_service/client.hpp`. Two
    /// bytes, and native-endian unlike everything around it - the framing is big-endian
    /// and the report inside is little-endian, and none of the three announces itself.
    static let clientProtocolVersion: UInt16 = 7
    /// The daemon's own cadence, measured: it sends a heartbeat every three seconds and
    /// drops a client silent for fifteen. Matching it keeps this side well inside the
    /// patience of a daemon whose patience is not written down anywhere this side can read.
    static let heartbeatInterval: Duration = .seconds(3)

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

    private let link: Link

    /// Connects to the daemon at the path above.
    ///
    /// `whenLost` is told, once, from the reading thread, when the connection ends for
    /// any reason but this side hanging up: the daemon closed it, the socket failed, or
    /// the wire carried something this side cannot read. Every later request throws the
    /// same failure, so a caller that only ever asks can leave it be; a process that
    /// holds the connection open across long silences is the one that needs to hear.
    convenience init(whenLost: @escaping @Sendable (DaemonError) -> Void = { _ in }) throws {
        guard FileManager.default.fileExists(atPath: Self.socketPath) else { throw DaemonError.noSocket(path: Self.socketPath) }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DaemonError.socket("socket", errno) }
        // Connected before anything reads it: a reader on an unconnected socket reports a
        // failure that is really this side's own ordering. The descriptor has no owner
        // yet, so a refused connection closes it here and nowhere else.
        do { try Self.connect(descriptor) } catch { close(descriptor); throw error }
        try self.init(fileDescriptor: descriptor, whenLost: whenLost)
    }

    /// A connection over a descriptor someone else opened. This is the seam that makes
    /// the wire protocol testable: a `socketpair` puts a fake daemon on the other end, so
    /// the framing, the deadlines, the heartbeats and the request/response matching are
    /// exercised over a real socket rather than mocked away. [LAW:decomposition] The
    /// protocol and the pipe it runs over are two things, and only one of them needs root.
    ///
    /// The heartbeat interval is a parameter so a test can watch one go out without
    /// waiting the daemon's three seconds for it.
    init(fileDescriptor: Int32, heartbeatEvery interval: Duration = DaemonConnection.heartbeatInterval, whenLost: @escaping @Sendable (DaemonError) -> Void = { _ in }) throws {
        // The link owns the descriptor from this line, so an initializer that throws past
        // it still closes exactly once, when the link goes.
        link = Link(socket: fileDescriptor, heartbeatEvery: interval, whenLost: whenLost)
        try refuseSIGPIPE(fileDescriptor)
        link.startReading()
    }

    /// Hangs up. The reading thread sees the end of the stream, finishes, and lets go of
    /// the link, which is when the descriptor closes. [LAW:single-enforcer]
    deinit {
        link.hangUp()
    }

    private static func connect(_ socket: Int32) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(Self.socketPath.utf8CString)
        precondition(path.count <= MemoryLayout.size(ofValue: address.sun_path), "the socket path outgrew sun_path")
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.map { UInt8(bitPattern: $0) }) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw DaemonError.socket("connect", errno) }
    }

    // MARK: - Requests

    /// The daemon's latest word on each status it has ever sent.
    var status: [Status: Bool] { link.currentStatus }

    /// Sends a request and waits for the daemon's answer to it. Every request is answered,
    /// including a posted report, so waiting on the answer is real flow control rather
    /// than a sleep guessed at. [LAW:no-ambient-temporal-coupling]
    func request(_ request: Request, _ payload: [UInt8] = [], by deadline: ContinuousClock.Instant) throws {
        let version = Self.clientProtocolVersion
        let body = [UInt8(version & 0xff), UInt8(version >> 8), request.rawValue] + payload
        let id = try link.send(body)
        try link.wait(by: deadline) { $0.answered.remove(id) != nil }
    }

    /// Waits until the daemon has said the keyboard is ready, however long ago it said so.
    /// The wait is on the daemon's word, never a sleep - but note what the word costs: the
    /// daemon asks the driver once a second, so readiness is *discovered* on the next tick
    /// rather than when it happened, and this takes up to a second however fast the device
    /// really was. That is why a connection is meant to be held open rather than made per
    /// insert.
    func awaitKeyboardReady(by deadline: ContinuousClock.Instant) throws {
        try link.wait(by: deadline) { $0.status[.keyboardReady] == true }
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
}

/// What the reading thread and the connection share: the socket, and everything the
/// daemon has said that someone might be waiting on.
///
/// Its own type rather than state on `DaemonConnection` so that the thread holds this and
/// not the connection: a thread holding the connection would keep it alive for as long as
/// the daemon kept talking, and `deinit` would never come. The connection hangs up; the
/// thread notices, ends, and lets go; the descriptor closes with the last holder.
/// [LAW:no-shared-mutable-globals] One lock guards all of it, and every read and write of
/// the fields below happens under it.
private final class Link: @unchecked Sendable {
    private let socket: Int32
    private let heartbeatInterval: Duration
    private let whenLost: @Sendable (DaemonError) -> Void
    private let guarded = NSCondition()
    private var nextRequestID: UInt64 = 1
    /// Ids the daemon has answered that nobody has yet collected.
    var answered: Set<UInt64> = []
    var status: [DaemonConnection.Status: Bool] = [:]
    /// Set once, by whichever side ended the connection, and never cleared: every wait
    /// after it throws this, because the daemon cannot answer on a stream that is gone.
    private var failure: DaemonError?
    /// True when this side hung up, so the end of the stream that follows is not reported
    /// as the daemon's doing.
    private var hungUp = false

    init(socket: Int32, heartbeatEvery interval: Duration, whenLost: @escaping @Sendable (DaemonError) -> Void) {
        self.socket = socket
        heartbeatInterval = interval
        self.whenLost = whenLost
    }

    deinit {
        close(socket)
    }

    var currentStatus: [DaemonConnection.Status: Bool] {
        guarded.lock(); defer { guarded.unlock() }
        return status
    }

    // MARK: Asking

    /// Writes a request frame and returns the id the answer will carry.
    func send(_ body: [UInt8]) throws -> UInt64 {
        guarded.lock(); defer { guarded.unlock() }
        if let failure { throw failure }
        let id = nextRequestID
        nextRequestID += 1
        try write(Frame.request(id: id, payload: body).bytes)
        return id
    }

    /// Blocks until `satisfied` holds, the connection has failed, or the deadline passes,
    /// in that order of precedence: an answer that arrived is an answer, even on a stream
    /// that ended just after it. [LAW:no-silent-failure] A daemon that says nothing is a
    /// named failure at the deadline, not a wait without end.
    func wait(by deadline: ContinuousClock.Instant, until satisfied: (Link) -> Bool) throws {
        guarded.lock(); defer { guarded.unlock() }
        while true {
            if satisfied(self) { return }
            if let failure { throw failure }
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw DaemonError.silent }
            guarded.wait(until: Date(timeIntervalSinceNow: remaining.seconds))
        }
    }

    // MARK: Reading

    /// Reads until the stream ends, on a thread that holds this link and nothing else.
    func startReading() {
        let thread = Thread { [self] in
            do {
                try readUntilTheEnd()
            } catch {
                lost(error as? DaemonError ?? DaemonError.malformed("\(error)"))
            }
        }
        thread.name = "DaemonConnection.reader"
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// The next thing to do is always the same: wait for the daemon or the heartbeat's
    /// turn, whichever comes first, then do whichever came. [LAW:dataflow-not-control-flow]
    private func readUntilTheEnd() throws {
        var heartbeatDue = ContinuousClock.now + heartbeatInterval
        while true {
            var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            let readable = poll(&descriptor, 1, max(0, (heartbeatDue - ContinuousClock.now).wholeMilliseconds))
            // Around the loop rather than retried in place, so the heartbeat's turn is
            // consulted again with the time actually left.
            if readable < 0, errno == EINTR { continue }
            guard readable >= 0 else { throw DaemonError.socket("poll", errno) }
            if ContinuousClock.now >= heartbeatDue {
                guarded.lock(); defer { guarded.unlock() }
                try write(Frame.control(.heartbeat, payload: []).bytes)
                heartbeatDue += heartbeatInterval
            }
            if readable > 0 {
                try handle(try readFrame())
            }
        }
    }

    /// What every frame means to this side: a pushed status is recorded and answered with
    /// an empty response, as pqrs's own client does; a health check is answered; a
    /// response's status pairs are recorded and its id is kept for whoever asked.
    private func handle(_ frame: Frame) throws {
        guarded.lock(); defer { guarded.unlock() }
        switch frame {
        case .control(.healthCheck, _):
            try write(Frame.control(.healthCheckResponse, payload: []).bytes)
        case .control:
            break
        case .request(let id, let payload):
            try record(payload)
            try write(Frame.response(id: id, payload: []).bytes)
        case .response(let id, let payload):
            try record(payload)
            answered.insert(id)
        }
        // [LAW:single-enforcer] Version skew is a hard failure wherever it arrives, not a
        // note on the way past. A driver built for another protocol accepts reports and
        // then does something other than what they say, so there is no degraded mode to
        // continue into.
        guard status[.driverVersionMismatched] != true else { throw DaemonError.driverVersionMismatched }
        guarded.broadcast()
    }

    private func record(_ pairs: [UInt8]) throws {
        for (status, value) in try DaemonConnection.statusPairs(pairs) {
            self.status[status] = value
        }
    }

    // MARK: Ending

    /// This side is done. The stream ends for the reader, which is how it stops.
    func hangUp() {
        guarded.lock()
        hungUp = true
        guarded.unlock()
        shutdown(socket, SHUT_RDWR)
    }

    /// The connection ended and this side did not end it. Recorded once, every waiter
    /// woken to throw it, and the owner told - after the lock is released, so an owner
    /// that answers by touching the connection cannot deadlock against this thread.
    private func lost(_ error: DaemonError) {
        guarded.lock()
        let first = failure == nil
        if first { failure = error }
        let theirs = first && !hungUp
        guarded.broadcast()
        guarded.unlock()
        if theirs { whenLost(error) }
    }

    // MARK: The socket

    private func readFrame() throws -> Frame {
        let length = try Frame.bodyLength(header: read(4))
        return try Frame.decode(body: read(length))
    }

    /// Only ever called with the lock held: two writers interleaving would put half of
    /// one frame inside another.
    private func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = uninterrupted { bytes[offset...].withUnsafeBytes { Darwin.write(socket, $0.baseAddress, $0.count) } }
            guard written > 0 else { throw DaemonError.socket("write", errno) }
            offset += written
        }
    }

    private func read(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let got = uninterrupted { bytes[offset...].withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress, $0.count) } }
            guard got > 0 else { throw got == 0 ? DaemonError.closed : DaemonError.socket("read", errno) }
            offset += got
        }
        return bytes
    }
}

private extension Duration {
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }

    var wholeMilliseconds: Int32 {
        Int32(clamping: components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
