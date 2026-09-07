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
///
/// **One connection carries both devices.** The daemon keeps a keyboard and a pointing
/// device per client connection and destroys both when the client hangs up, so a helper
/// that owns a keyboard and a mouse holds one of these and hands it to each.
public final class DaemonConnection: Sendable {
    static let socketPath = "/Library/Application Support/org.pqrs/tmp/rootonly/karabiner_virtual_hid_device_service.sock"
    /// The version this side speaks, from `virtual_hid_device_service/client.hpp`. Two
    /// bytes, and native-endian unlike everything around it - the framing is big-endian
    /// and the report inside is little-endian, and none of the three announces itself.
    static let clientProtocolVersion: UInt16 = 7
    /// The daemon's own cadence, measured: it sends a heartbeat every three seconds and
    /// drops a client silent for fifteen. Matching it keeps this side well inside the
    /// patience of a daemon whose patience is not written down anywhere this side can read.
    static let heartbeatInterval: Duration = .seconds(3)
    /// How long the daemon may say nothing before it is taken for gone: its own fifteen
    /// seconds, mirrored. A peer that stalled without closing - suspended, wedged mid-frame
    /// - sends no heartbeat and no end of stream, and a reader that only waits for one of
    /// those would wait forever, sending its own heartbeats into the dark.
    static let patience: Duration = .seconds(15)

    /// The request table, by index, from `virtual_hid_device_service/request.hpp`.
    enum Request: UInt8 {
        case keyboardInitialize = 0
        case keyboardTerminate = 1
        case keyboardReset = 2
        case pointingInitialize = 3
        case pointingTerminate = 4
        case pointingReset = 5
        case postKeyboardInputReport = 6
        case postPointingInputReport = 11
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
    public convenience init(whenLost: @escaping @Sendable (DaemonError) -> Void = { _ in }) throws {
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
    /// The heartbeat interval and the patience are parameters so a test can watch a
    /// heartbeat go out, or a silence be noticed, without waiting the daemon's seconds.
    init(fileDescriptor: Int32, heartbeatEvery interval: Duration = DaemonConnection.heartbeatInterval, patience: Duration = DaemonConnection.patience, whenLost: @escaping @Sendable (DaemonError) -> Void = { _ in }) throws {
        // The link owns the descriptor from this line, so an initializer that throws past
        // it still closes exactly once, when the link goes.
        link = Link(socket: fileDescriptor, heartbeatEvery: interval, patience: patience, whenLost: whenLost)
        try refuseSIGPIPE(fileDescriptor)
        try neverBlock(fileDescriptor)
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
        // On every way out, so an answer to a request nobody waits on any more is dropped
        // at the door rather than kept for a collector that never comes.
        defer { link.forget(id) }
        try link.wait(by: deadline) { $0.requests[id] == true }
    }

    /// Waits until the daemon has said `status` holds, however long ago it said so. The
    /// wait is on the daemon's word, never a sleep - but note what the word costs: the
    /// daemon asks the driver once a second, so readiness is *discovered* on the next tick
    /// rather than when it happened, and this takes up to a second however fast the device
    /// really was. That is why a connection is meant to be held open rather than made per
    /// insert.
    func wait(for status: Status, by deadline: ContinuousClock.Instant) throws {
        try link.wait(by: deadline) { $0.status[status] == true }
    }

    /// Brings one device up: sends its initialize request with `payload`, then waits for
    /// the daemon's word that the device is `ready`, in at most `limit` altogether. Both
    /// devices start this way and differ only in the three values, so the bringing up is
    /// one function of them. [LAW:one-type-per-behavior]
    func initialize(_ request: Request, _ payload: [UInt8], until ready: Status, within limit: Duration) throws -> Startup {
        let began = ContinuousClock.now
        let deadline = began + limit
        try self.request(request, payload, by: deadline)
        // Taken here because `request` returns on the daemon's answer to it. Timing the
        // first frame of the readiness wait instead - as this did, and the spike before
        // it - reports the first status push under a name that says the daemon had not
        // spoken yet, when answering the request is exactly what it just did.
        let answered = ContinuousClock.now
        try wait(for: ready, by: deadline)
        return Startup(answered: answered - began, ready: ContinuousClock.now - began)
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
    private let patience: Duration
    private let whenLost: @Sendable (DaemonError) -> Void
    private let guarded = NSCondition()
    private var nextRequestID: UInt64 = 1
    /// Every request someone is still waiting on, and whether the daemon has answered it.
    /// [LAW:one-source-of-truth] One table rather than a set of the asked and a set of
    /// the answered: an id is here while a waiter wants it and nowhere once it does not.
    var requests: [UInt64: Bool] = [:]
    var status: [DaemonConnection.Status: Bool] = [:]
    /// When the daemon last sent a byte. Read and written by the reading thread alone, so
    /// it needs no lock: nothing else has a reason to know.
    ///
    /// On the clock that stops with the Mac: the silence that says anything about the
    /// daemon is silence while both were awake, and a clock that ran on through the lid
    /// being closed would find the daemon fifteen seconds gone the instant it opened.
    /// Request deadlines stay on `ContinuousClock`; they are short and a caller's.
    /// [LAW:no-ambient-temporal-coupling]
    private var lastHeard = SuspendingClock.now
    /// Set once, by whichever side ended the connection, and never cleared: every wait
    /// after it throws this, because the daemon cannot answer on a stream that is gone.
    private var failure: DaemonError?
    /// True when this side hung up, so the end of the stream that follows is not reported
    /// as the daemon's doing.
    private var hungUp = false

    init(socket: Int32, heartbeatEvery interval: Duration, patience: Duration, whenLost: @escaping @Sendable (DaemonError) -> Void) {
        self.socket = socket
        heartbeatInterval = interval
        self.patience = patience
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
    ///
    /// A write that fails is the connection ending, and it ends here the way it ends on
    /// the reading thread: recorded once, every waiter woken, the owner told.
    /// [LAW:single-enforcer] A daemon that died between two frames is otherwise found
    /// dead by whichever side wrote first, and only one of the two would have said so.
    func send(_ body: [UInt8]) throws -> UInt64 {
        guarded.lock()
        if let failure { guarded.unlock(); throw failure }
        let id = nextRequestID
        nextRequestID += 1
        do {
            try write(Frame.request(id: id, payload: body).bytes)
        } catch {
            let theirs = record(loss: error)
            guarded.unlock()
            if theirs { whenLost(error) }
            throw error
        }
        requests[id] = false
        guarded.unlock()
        return id
    }

    /// The request is nobody's concern any more, answered or not.
    func forget(_ id: UInt64) {
        guarded.lock(); defer { guarded.unlock() }
        requests[id] = nil
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

    /// The next thing to do is always the same: wait for the daemon, the heartbeat's turn
    /// or the end of the patience, whichever comes first, then do whichever came.
    /// [LAW:dataflow-not-control-flow]
    private func readUntilTheEnd() throws {
        var heartbeatDue = SuspendingClock.now + heartbeatInterval
        while true {
            let readable = try ready(POLLIN, by: min(heartbeatDue, lastHeard + patience))
            if SuspendingClock.now >= heartbeatDue {
                guarded.lock(); defer { guarded.unlock() }
                try write(Frame.control(.heartbeat, payload: []).bytes)
                heartbeatDue += heartbeatInterval
            }
            if readable {
                try handle(try readFrame())
            }
            guard SuspendingClock.now < lastHeard + patience else { throw DaemonError.silent }
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
            // Only a request still waited on: `nil` is not a key, so an answer to a
            // forgotten one records nothing. [LAW:dataflow-not-control-flow]
            requests[id] = requests[id].map { _ in true }
        }
        guarded.broadcast()
    }

    /// Records what the daemon said about its status. Version skew throws from here, before
    /// the frame that carried it can count as an answer: a waiter woken by the loss then
    /// finds the failure and not an acknowledgement. [LAW:single-enforcer] A driver built
    /// for another protocol accepts reports and then does something other than what they
    /// say, so there is no degraded mode to continue into.
    private func record(_ pairs: [UInt8]) throws {
        for (status, value) in try DaemonConnection.statusPairs(pairs) {
            self.status[status] = value
        }
        guard status[.driverVersionMismatched] != true else { throw DaemonError.driverVersionMismatched }
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
        let theirs = record(loss: error)
        guarded.unlock()
        if theirs { whenLost(error) }
    }

    /// The locked half of losing the connection: the first loss is the failure every
    /// waiter throws, and every waiter is woken. Answers whether the owner is owed the
    /// news, which is once, and never for an end this side asked for. Only ever called
    /// with the lock held.
    private func record(loss error: DaemonError) -> Bool {
        let first = failure == nil
        if first { failure = error }
        guarded.broadcast()
        return first && !hungUp
    }

    // MARK: The socket

    private func readFrame() throws -> Frame {
        let length = try Frame.bodyLength(header: read(4))
        return try Frame.decode(body: read(length))
    }

    /// Only ever called with the lock held: two writers interleaving would put half of
    /// one frame inside another.
    ///
    /// Each chunk is waited for within the patience, like a read: a peer that stops
    /// draining without hanging up fills the kernel's buffer and then takes every writer
    /// - and, through the lock, every waiter - with it, and that is the same silence a
    /// stalled read is.
    private func write(_ bytes: [UInt8]) throws(DaemonError) {
        var offset = 0
        while offset < bytes.count {
            guard try ready(POLLOUT, by: .now + patience) else { throw DaemonError.silent }
            let written = uninterrupted { bytes[offset...].withUnsafeBytes { Darwin.write(socket, $0.baseAddress, $0.count) } }
            // Room reported and gone again before the call: back to waiting for it.
            if written < 0, errno == EAGAIN { continue }
            guard written > 0 else { throw DaemonError.socket("write", errno) }
            offset += written
        }
    }

    /// Reads exactly `count` bytes, each chunk waited for within the patience: a peer that
    /// stops mid-frame is as gone as one that stops between frames.
    private func read(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            guard try ready(POLLIN, by: lastHeard + patience) else { throw DaemonError.silent }
            let got = uninterrupted { bytes[offset...].withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress, $0.count) } }
            if got < 0, errno == EAGAIN { continue }
            guard got > 0 else { throw got == 0 ? DaemonError.closed : DaemonError.socket("read", errno) }
            offset += got
            lastHeard = SuspendingClock.now
        }
        return bytes
    }

    /// Whether the socket is ready for `events` - something to read, or room to write - by
    /// `deadline`. The one wait on the socket, so the end of the stream, an interrupted
    /// call and a failed poll each have one reading. [LAW:single-enforcer]
    private func ready(_ events: Int32, by deadline: SuspendingClock.Instant) throws(DaemonError) -> Bool {
        while true {
            var descriptor = pollfd(fd: socket, events: Int16(events), revents: 0)
            let ready = poll(&descriptor, 1, max(0, (deadline - SuspendingClock.now).wholeMilliseconds))
            // Around the loop rather than retried in place, so the time actually left is
            // consulted again.
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { throw DaemonError.socket("poll", errno) }
            return ready > 0
        }
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
