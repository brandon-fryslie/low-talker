import AppKit
import ApplicationServices
import ArgumentParser
import Foundation
import LowTalkerCore

/// The spike behind low-keyboard-3ti.2: keystrokes sent to the
/// Karabiner-DriverKit-VirtualHIDDevice driver extension from this process, with as
/// little between as macOS allows, to measure the premise before a module or a helper
/// exists.
///
/// What macOS allows is less than the ticket assumed. The extension's user client
/// opens only for a process holding `com.apple.developer.driverkit.userclient-access`
/// for its bundle id, an entitlement Apple grants per app id; root without it gets
/// kIOReturnNotPermitted, measured here. The package ships the one process that holds
/// it, Karabiner-VirtualHIDDevice-Daemon, which runs as root and takes reports over a
/// Unix domain socket in a root-only directory. That socket is the way in, and root is
/// what it takes to reach it: `type` needs sudo. `watch` runs as the user and needs
/// the terminal's Input Monitoring and Accessibility, like `hotkey`.
struct DextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dext",
        abstract: "Type through the virtual keyboard driver extension, and watch what arrives.",
        subcommands: [DextTypeCommand.self, DextWatchCommand.self]
    )
}

/// Types text into a named app as the virtual keyboard and reads it back off that app's
/// focused element through Accessibility, so what it prints is measured, not assumed.
/// Naming the app is what keeps a window that steals focus from swallowing the text.
struct DextTypeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text through the driver extension into a named app (needs sudo)."
    )

    @Argument(help: "The bundle id of the app to type into, e.g. com.apple.TextEdit.")
    var into: BundleID

    @Argument(help: "The text to type: printable ASCII, newline, and tab.")
    var text: String

    @MainActor
    func run() async throws {
        // [LAW:parse-dont-validate] The text is proven typeable before the daemon is
        // touched, so a refusal leaves no half-typed line behind.
        let keystrokes = try USLayout.keystrokes(for: text)
        let clock = ContinuousClock()
        let connecting = clock.now
        // Watched before a single report goes out, so there is no window where an
        // interrupt can end the process with a key already down.
        let interrupt = Interrupt.watched()
        let daemon = try DaemonConnection()
        // [LAW:single-enforcer] Every key is released on every way out this process
        // controls. A press is two requests, so a throw between them - a socket timeout,
        // a focus check that fails, the operator's Ctrl-C - leaves that key held, and
        // macOS repeats a held key until something releases it. One place enforces that,
        // not each throw site.
        defer {
            do { try daemon.request(.keyboardReset, [], within: .seconds(2)) }
            // [LAW:no-silent-failure] Nowhere to throw from a defer, so it is said out
            // loud: a key may be left held and the next thing typed will show it.
            catch { print("the keyboard was not reset: \(error). A key may be left held.") }
        }
        try daemon.request(.keyboardInitialize, DaemonConnection.keyboardParameters, within: .seconds(2))
        let readyAfter = try daemon.awaitKeyboardReady(within: .seconds(2))
        print("daemon answered in \((readyAfter.answered - connecting).milliseconds) ms, keyboard ready after \((readyAfter.ready - connecting).milliseconds) ms")

        // [LAW:no-ambient-temporal-coupling] The target is stated, not discovered, and
        // every read re-checks it, so a window that steals focus mid-run is a named
        // failure rather than text delivered somewhere nobody asked for.
        let screen = TargetApp(bundleID: into, interrupt: interrupt)
        try interrupt.check()
        try await screen.raise(within: .seconds(5))
        let start = try screen.focus()
        let before = start.text
        // Which element, not just which app: a find bar accepts keystrokes as readily as
        // a document, and reads them back just as convincingly.
        print("typing into \(into.rawValue), focus is \(start.role)")

        // From the first report on there is text in the document that cannot be taken
        // back, so every failure from here has to say how much of it landed. The guard is
        // over the region where that is true, not over one kind of error: catching only
        // ScreenUnreadable let a daemon timeout mid-burst walk past it, and leaving the
        // first press outside the block let its own failure past as well. What throws
        // does not change what the operator needs to be told. [LAW:single-enforcer]
        let first = keystrokes[0]
        let firstPosted = clock.now
        do {
            try interrupt.check()
            // One character alone, so its latency is the driver's and not the queue's.
            try daemon.press(first)
            let firstSeen = try await screen.wait(within: .seconds(3)) { $0.occurrences(of: String(first.character)) > before.occurrences(of: String(first.character)) }
            print("first character on screen in \(into.rawValue) after \((clock.now - firstPosted).milliseconds) ms\(firstSeen ? "" : " (NEVER SEEN)")")

            // Focus is re-checked before every keystroke, not once before the burst. A
            // keystroke is irrevocable the moment it is posted, so the window in which
            // focus may move has to be one keystroke wide; anything wider delivers the
            // rest of the text to whatever app took the front.
            // [LAW:no-ambient-temporal-coupling]
            let rest = Array(keystrokes.dropFirst())
            let restPosted = clock.now
            for keystroke in rest {
                try interrupt.check()
                try screen.requireFrontmost()
                try daemon.press(keystroke)
            }
            let acknowledged = clock.now - restPosted
            // Against a baseline, like the first character's check: an app already holding
            // this text would otherwise confirm a run that delivered nothing.
            let allSeen = try await screen.wait(within: .seconds(5)) { $0.occurrences(of: text) > before.occurrences(of: text) }
            let settled = clock.now - restPosted
            // The count is the one the clock actually covers: the first character was
            // posted and timed above, on its own, and is not in this window.
            // [LAW:one-source-of-truth] With nothing after that character there is no
            // burst, and no window either - "0 more in 0.0 ms, all 1 on screen after
            // 0.1 ms" is measured from after the character had already landed and reads
            // as a claim about it, which the line above has already made properly.
            if !rest.isEmpty {
                print("\(rest.count) more characters posted and acknowledged in \(acknowledged.milliseconds) ms, all \(keystrokes.count) on screen after \(settled.milliseconds) ms")
            }
            if allSeen {
                print("the screen holds the text, complete and in order")
            } else {
                // The mismatch report is the entire output of a bad run, so it is not
                // allowed to fail on its own account. A screen that will not be read is
                // part of the report, not a reason to lose it. [LAW:no-silent-failure]
                do { print("MISMATCH: the screen holds [\(try screen.read())]") }
                catch { print("MISMATCH, and the screen would not be read afterwards: \(error)") }
            }
        } catch {
            throw TypingStopped(typed: daemon.pressesBegun, of: keystrokes.count, cause: error)
        }
    }
}

/// Prints every keyboard event the login session carries, through the same tap the
/// app installs, with the time from the driver's stamp to the tap's callback.
struct DextWatchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Print each keyboard event the session's event tap sees until interrupted."
    )

    @MainActor
    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let (events, continuation) = AsyncStream.makeStream(of: (KeyEvent, Duration).self)
        _ = try SystemKeyboardTap().install(
            handling: { event in
                continuation.yield((event, .nanoseconds(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))))
                return .pass
            },
            onLapse: { print("the tap lapsed and was switched back on") }
        )
        print("watching the session's keyboard events")
        for await (event, arrived) in events {
            let key = switch event.key {
            case .key(let key): "key \(key.rawValue)"
            case .modifier(let modifier): "modifier \(modifier.rawValue)"
            }
            print("\(event.direction) \(key) stamp-to-tap \((arrived - event.time).microseconds) us")
        }
    }
}

// MARK: - The daemon's socket

/// One connection to Karabiner-VirtualHIDDevice-Daemon over its Unix domain stream
/// socket, speaking pqrs's framing by the numbers the pinned package fixes (8.4.0,
/// client protocol 7). Every failure names what the daemon did or did not say.
/// [LAW:no-silent-failure]
///
/// A frame is a 4-byte big-endian body length, a type byte, and for requests and
/// responses an 8-byte big-endian request id before the payload. A request payload
/// is the client protocol version (2 bytes, native order), the request byte, and the
/// request's own bytes. The daemon answers each request with a response frame of the
/// same id whose payload is (response, value) byte pairs, and pushes the same pairs
/// as requests of its own whenever the driver's state changes; those are answered
/// with an empty response, as pqrs's client does.
final class DaemonConnection {
    static let socketPath = "/Library/Application Support/org.pqrs/tmp/rootonly/karabiner_virtual_hid_device_service.sock"
    static let clientProtocolVersion: UInt16 = 7
    /// pqrs's own defaults for the virtual keyboard: vendor id, product id, and a
    /// country code of "not supported", each a uint64.
    static let keyboardParameters: [UInt8] = [0x16c0, 0x27db, 0].flatMap { (value: UInt64) in (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }

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

    /// The frame types, by index, from `unix_domain_stream/impl/protocol.hpp`.
    enum FrameType: UInt8 {
        case heartbeat = 0
        case userData = 1
        case healthCheck = 2
        case healthCheckResponse = 3
        case request = 4
        case response = 5
    }

    private let socket: Int32
    private var nextRequestID: UInt64 = 1
    /// The daemon's latest word on each status it has ever sent.
    private(set) var status: [Status: Bool] = [:]
    /// How many presses the daemon has acknowledged the key-down of. A press is two
    /// reports and the character is on screen after the first, so a failure between them
    /// still put a character in the document - counting completed presses would report
    /// one fewer than is actually there. The count belongs here because this is what
    /// sends them; a caller keeping its own tally keeps one that can disagree.
    /// [LAW:one-source-of-truth]
    private(set) var pressesBegun = 0

    init() throws {
        guard FileManager.default.fileExists(atPath: Self.socketPath) else { throw DaemonError.noSocket }
        socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw DaemonError.socket("socket", errno) }
        var noSignal: Int32 = 1
        // [LAW:no-silent-failure] This is the only thing standing between a write to a
        // closed socket and SIGPIPE killing the process without a word, so a failure to
        // set it is reported rather than assumed.
        guard setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw DaemonError.socket("setsockopt(SO_NOSIGPIPE)", errno)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(Self.socketPath.utf8CString)
        precondition(path.count <= MemoryLayout.size(ofValue: address.sun_path), "the socket path outgrew sun_path")
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.map { UInt8(bitPattern: $0) }) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            throw DaemonError.socket("connect", errno)
        }
    }

    /// The one place the descriptor closes. [LAW:single-enforcer] Every stored property
    /// is set by the line above, so an initializer that throws past that point still
    /// deallocates the instance and still runs this - and the explicit closes that used
    /// to stand in the throwing branches closed the same descriptor a second time. A
    /// second close usually fails with EBADF and is ignored, but the number it names is
    /// free to have been handed to something else by then.
    deinit {
        close(socket)
    }

    /// Sends a request and returns its id, without waiting for the answer.
    @discardableResult
    func send(_ request: Request, _ payload: [UInt8]) throws -> UInt64 {
        let id = nextRequestID
        nextRequestID += 1
        let version = Self.clientProtocolVersion
        let data = [UInt8(version & 0xff), UInt8(version >> 8), request.rawValue] + payload
        try write(Self.frame(.request, id: id, data))
        return id
    }

    /// Sends a request and waits for the daemon's answer to it.
    func request(_ request: Request, _ payload: [UInt8], within limit: Duration) throws {
        try awaitResponse(to: send(request, payload), within: limit)
    }

    /// A key down and back up: the two reports a HID keyboard sends for one press.
    ///
    /// Each report is awaited, and that is not politeness - it is flow control. Fired
    /// back to back with no wait, 500 characters overrun the path and reports are lost;
    /// a lost key-up leaves its key held, so macOS starts repeating it and the tail of
    /// the text becomes hundreds of one shifted character. Measured, twice, in this
    /// spike. The daemon answers every request, so its answer is a real signal to wait
    /// on rather than a sleep guessed at. [LAW:no-ambient-temporal-coupling]
    func press(_ keystroke: USLayout.Keystroke) throws {
        try request(.postKeyboardInputReport, KeyboardReport(modifiers: keystroke.shift ? KeyboardReport.leftShift : 0, keys: [keystroke.usage]).bytes, within: .seconds(2))
        pressesBegun += 1
        try request(.postKeyboardInputReport, KeyboardReport.released.bytes, within: .seconds(2))
    }

    /// Reads frames until the response to `id` arrives, taking in every status the
    /// daemon pushes on the way. [LAW:no-ambient-temporal-coupling] The wait is on the
    /// daemon's answer, and the bound is a failure, not a silence.
    func awaitResponse(to id: UInt64, within limit: Duration) throws {
        let deadline = ContinuousClock.now + limit
        while true {
            let (type, frameID, data) = try readFrame(by: deadline)
            try handle(type, id: frameID, data)
            if type == .response, frameID == id { return }
        }
    }

    /// Reads frames until the daemon has said the keyboard is ready, and says when it
    /// first answered at all and when it said so.
    func awaitKeyboardReady(within limit: Duration) throws -> (answered: ContinuousClock.Instant, ready: ContinuousClock.Instant) {
        let deadline = ContinuousClock.now + limit
        var answered: ContinuousClock.Instant?
        while status[.keyboardReady] != true {
            // Checked before the read, not after it: a mismatch pushed during an earlier
            // request is already recorded, and no further frame is coming to carry it.
            // Blocking here would bury the named cause under a timeout.
            // [LAW:no-silent-failure]
            guard status[.driverVersionMismatched] != true else { throw DaemonError.driverVersionMismatched }
            let (type, frameID, data) = try readFrame(by: deadline)
            try handle(type, id: frameID, data)
            answered = answered ?? ContinuousClock.now
        }
        return (answered ?? ContinuousClock.now, ContinuousClock.now)
    }

    /// What every frame means to this side: a pushed status is recorded and answered,
    /// a health check is answered, a response's status pairs are recorded.
    private func handle(_ type: FrameType, id: UInt64, _ data: [UInt8]) throws {
        switch type {
        case .heartbeat, .userData, .healthCheckResponse:
            break
        case .healthCheck:
            try write(Self.frame(.healthCheckResponse, id: nil, []))
        case .request:
            try record(data)
            try write(Self.frame(.response, id: id, []))
        case .response:
            try record(data)
        }
    }

    /// The daemon's status payload, decoded: pairs of (status, value). Pure, and here
    /// rather than inside record for the same reason the framing is - a transposed pair
    /// records the wrong status as true and nothing about that looks wrong at runtime.
    /// [LAW:decomposition]
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

    /// The framing is bytes alone, with no socket in it. Byte order is the part of a
    /// protocol that goes wrong silently - a reasonable-looking guess at pqrs's layout
    /// would have corrupted every report while looking perfectly healthy - so the part
    /// that decides it is separated from the part that does I/O, where it can be proven
    /// by a test rather than only by a live driver. [LAW:decomposition]
    static func frame(_ type: FrameType, id: UInt64?, _ data: [UInt8]) -> [UInt8] {
        let requestID = id.map { id in (0..<8).reversed().map { UInt8(truncatingIfNeeded: id >> (8 * $0)) } } ?? []
        let body = [type.rawValue] + requestID + data
        let length = UInt32(body.count)
        return (0..<4).reversed().map { UInt8(truncatingIfNeeded: length >> (8 * $0)) } + body
    }

    /// EINTR says the call did not happen and must be made again, which is the opposite
    /// of a failure - and reporting a non-failure as one is the same lie as the reverse.
    /// [LAW:no-silent-failure] A signal delivered during a run is enough to trip this: a
    /// terminal resize while typing into iTerm2 would otherwise abort a connection that
    /// is perfectly healthy. Used for the data calls only; poll is retried by its own
    /// loop, which recomputes the timeout it has left rather than starting it over.
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

    /// The other half of the framing, and the same reason it is here: pure bytes in,
    /// meaning out. [LAW:decomposition]
    /// The largest frame this side will allocate for. A keyboard report is 67 bytes and
    /// the framing around it nine more; every response the daemon sends is shorter. The
    /// cap is generous by two orders of magnitude and still refuses the four-gigabyte
    /// allocation a desynced or corrupted header can otherwise ask for - which would end
    /// the process rather than name what the daemon said, and naming it is this class's
    /// whole promise.
    static let largestFrame = 4096

    static func bodyLength(header: [UInt8]) throws -> Int {
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        // [LAW:parse-dont-validate] The length is sane by the time it leaves here, so
        // nothing downstream allocates against a number it has to think about first.
        guard length >= 1 else { throw DaemonError.malformed("an empty frame") }
        guard length <= largestFrame else { throw DaemonError.malformed("a frame of \(length) bytes, past the \(largestFrame) this reads") }
        return length
    }

    static func parse(body: [UInt8]) throws -> (FrameType, UInt64, [UInt8]) {
        guard let type = FrameType(rawValue: body[0]) else { throw DaemonError.malformed("frame type \(body[0]), which this was not written for") }
        switch type {
        case .request, .response:
            guard body.count >= 9 else { throw DaemonError.malformed("a \(type) frame of \(body.count) bytes, too short for its id") }
            let id = body[1..<9].reduce(0) { $0 << 8 | UInt64($1) }
            return (type, id, Array(body[9...]))
        default:
            return (type, 0, Array(body[1...]))
        }
    }

    private func readFrame(by deadline: ContinuousClock.Instant) throws -> (FrameType, UInt64, [UInt8]) {
        let length = try Self.bodyLength(header: read(4, by: deadline))
        return try Self.parse(body: read(length, by: deadline))
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

/// The keyboard input report as the driver's packed `keyboard_input` lays it out:
/// report id 1, one byte of modifier bits, one reserved byte, then 32 little-endian
/// usages from keyboard page 0x07 for the keys held. 67 bytes.
struct KeyboardReport {
    static let leftShift: UInt8 = 0x02
    static let released = KeyboardReport(modifiers: 0, keys: [])

    let modifiers: UInt8
    let keys: [UInt16]

    var bytes: [UInt8] {
        precondition(keys.count <= 32, "a keyboard report holds at most 32 keys")
        let padded = keys + Array(repeating: 0, count: 32 - keys.count)
        return [1, modifiers, 0] + padded.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
    }
}

enum DaemonError: Error, CustomStringConvertible {
    case noSocket
    case socket(String, Int32)
    case silent
    case closed
    case malformed(String)
    case driverVersionMismatched

    var description: String {
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

// MARK: - Characters to keystrokes

/// The spike's alphabet: printable ASCII plus newline and tab, as the US layout types
/// them. The layout's own map, dead keys included, is low-keyboard-3ti.4's work.
enum USLayout {
    struct Keystroke {
        let character: Character
        let usage: UInt16
        let shift: Bool
    }

    private typealias Row = (usage: UInt16, plain: Character, shifted: Character?)

    /// Usages that run in the order of the characters they type: letters from 0x04,
    /// digits from 0x1e.
    private static func run(from usage: UInt16, _ plain: String, _ shifted: String) -> [Row] {
        zip(plain, shifted).enumerated().map { Row(usage + UInt16($0.offset), $0.element.0, $0.element.1) }
    }

    /// Keyboard page 0x07, from the HID Usage Tables: each usage with the character
    /// it types bare and the one it types under Shift.
    private static let punctuation: [Row] = [
        (0x28, "\n", nil), (0x2b, "\t", nil), (0x2c, " ", nil),
        (0x2d, "-", "_"), (0x2e, "=", "+"), (0x2f, "[", "{"), (0x30, "]", "}"), (0x31, "\\", "|"),
        (0x33, ";", ":"), (0x34, "'", "\""), (0x35, "`", "~"), (0x36, ",", "<"), (0x37, ".", ">"), (0x38, "/", "?"),
    ]

    private static let table: [Row] =
        run(from: 0x04, "abcdefghijklmnopqrstuvwxyz", "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        + run(from: 0x1e, "1234567890", "!@#$%^&*()")
        + punctuation

    private static let keystrokes: [Character: Keystroke] = Dictionary(uniqueKeysWithValues: table.flatMap { row in
        [(row.plain, Keystroke(character: row.plain, usage: row.usage, shift: false))]
            + (row.shifted.map { [($0, Keystroke(character: $0, usage: row.usage, shift: true))] } ?? [])
    })

    /// [LAW:parse-dont-validate] The one place text becomes keystrokes; a character
    /// outside the alphabet is refused here, by name, and nothing downstream checks.
    static func keystrokes(for text: String) throws -> [Keystroke] {
        let untypeable = text.filter { keystrokes[$0] == nil }
        guard untypeable.isEmpty else { throw UntypeableCharacters(characters: String(untypeable)) }
        guard !text.isEmpty else { throw ValidationError("there is nothing to type") }
        return text.map { keystrokes[$0]! }
    }
}

extension BundleID: ExpressibleByArgument {}

/// A run that stopped once text was already in the target: focus moved, the daemon went
/// quiet, the operator interrupted it. What stopped it is the cause; how much is in the
/// document is the part only this knows, and the part the operator has to act on, since
/// text already typed cannot be taken back.
struct TypingStopped: Error, CustomStringConvertible {
    let typed: Int
    let of: Int
    let cause: any Error
    var description: String {
        // "Posted and acknowledged", not "typed", and the difference is this spike's
        // whole finding: the daemon acknowledges reports the driver then drops, so the
        // count is what left here and an upper bound on what landed, never a delivery
        // receipt. A run interrupted at 445 has been seen to leave 436 in the document.
        let progress = typed < of
            ? "\(typed) of \(of) characters had been posted and acknowledged before this, and the rest were not sent"
            : "all \(of) characters had been posted and acknowledged before this"
        return "\(cause). \(progress)"
    }
}

/// Ctrl-C, as a value the run reads rather than a way out that skips the run's own
/// ending. SIGINT's default disposition ends the process where it stands, so an interrupt
/// during a burst leaves a key down with nothing left to release it, and macOS repeats
/// that key into whatever app comes forward next - the exact failure this command exists
/// to study. Ignored as a signal and watched as a source instead, it becomes something
/// the run can read and stop for, unwinding through the same release every other
/// failure takes. [LAW:dataflow-not-control-flow]
///
/// Being ignored has a price worth stating plainly: the signal no longer ends a blocking
/// read either, so it is seen only where something asks. Every loop that waits on another
/// process asks - raising the app, polling the screen, each keystroke of the burst - and
/// so does each step between them. What is left is the daemon's own reads, so an
/// interrupt arriving inside one is seen when that read returns, at most two seconds
/// later.
final class Interrupt: @unchecked Sendable {
    private let lock = NSLock()
    private var raised: Int32?
    private var sources: [any DispatchSourceSignal] = []

    static func watched(_ numbers: [Int32] = [SIGINT, SIGTERM]) -> Interrupt {
        let interrupt = Interrupt()
        interrupt.sources = numbers.map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { interrupt.raise(number) }
            return source
        }
        interrupt.sources.forEach { $0.resume() }
        return interrupt
    }

    private func raise(_ number: Int32) {
        lock.lock()
        defer { lock.unlock() }
        raised = raised ?? number
    }

    /// [LAW:no-silent-failure] An interrupt is a named failure like any other, so it
    /// travels the same path and is reported with the same count beside it.
    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if let raised { throw Interrupted(number: raised) }
    }
}

struct Interrupted: Error, CustomStringConvertible {
    let number: Int32
    var description: String { "interrupted by signal \(number)" }
}

struct UntypeableCharacters: Error, CustomStringConvertible {
    let characters: String
    var description: String { "the US layout spike cannot type \(characters.debugDescription); it knows printable ASCII, newline, and tab" }
}

// MARK: - Reading the screen back

/// The one app this run types into: raised so the keystrokes land there, then read
/// back through Accessibility — the document in TextEdit, the screen in Terminal.
@MainActor
struct TargetApp {
    /// The app the caller means to type into; anything else in front is a refusal.
    /// [LAW:one-type-per-behavior] BundleID already names an app target everywhere else
    /// in this codebase, so this seam speaks it rather than a second bare String.
    let bundleID: BundleID
    /// Every loop in here waits on another process, and a wait is where an interrupt
    /// arrives. Ignoring the signal to keep it away from the driver's key state means
    /// nothing observes it unless something asks, so each poll asks.
    let interrupt: Interrupt

    /// Brings the target to the front and waits for macOS to agree it is there.
    /// [LAW:no-ambient-temporal-coupling] Focus is a state this command drives and
    /// confirms, never a condition it hopes the shell arranged beforehand.
    func raise(within limit: Duration) async throws {
        guard let target = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID.rawValue }) else {
            throw ScreenUnreadable.notRunning(bundleID.rawValue)
        }
        let clock = ContinuousClock()
        let start = clock.now
        repeat {
            try interrupt.check()
            target.activate()
            try await Task.sleep(for: .milliseconds(100))
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID.rawValue { return }
        } while clock.now - start < limit
        throw ScreenUnreadable.wouldNotComeForward(wanted: bundleID.rawValue, frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nothing")
    }

    /// [LAW:parse-dont-validate] The one place focus is decided. It returns the target
    /// app only when the target is the app in front, so a caller holding the result holds
    /// the proof and nothing downstream asks again. [LAW:single-enforcer]
    @discardableResult
    func requireFrontmost() throws -> NSRunningApplication {
        guard let app = NSWorkspace.shared.frontmostApplication else { throw ScreenUnreadable.noFrontmostApp }
        let name = app.bundleIdentifier ?? "pid \(app.processIdentifier)"
        guard name == bundleID.rawValue else { throw ScreenUnreadable.wrongApp(wanted: bundleID.rawValue, frontmost: name) }
        return app
    }

    /// What the app's focus actually is, and what it holds. The role travels with the
    /// text because naming the app does not name the element inside it: a find bar, a
    /// search field and the document are all equally "frontmost", and a run that types
    /// into the wrong one reads its own text back and calls itself correct.
    struct Focus {
        let role: String
        let text: String
    }

    /// [LAW:no-silent-failure] A screen that cannot be read is said so, never reported
    /// as an empty one: empty is what the verdict compares against.
    func focus() throws -> Focus {
        let (element, name) = try focusedElement()
        var role: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return Focus(role: role as? String ?? "an element that will not name its role", text: try Self.text(of: element, in: name))
    }

    /// The value alone. [LAW:decomposition] `wait` polls this every 2 ms for seconds at a
    /// time, and the role it does not use is another synchronous call into the app whose
    /// main thread the poll rate was chosen to leave alone - the reading would have been
    /// loading the very thing it measures.
    func read() throws -> String {
        let (element, name) = try focusedElement()
        return try Self.text(of: element, in: name)
    }

    private static func text(of element: AXUIElement, in name: String) throws -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success, let text = value as? String else { throw ScreenUnreadable.noText(name) }
        return text
    }

    /// The focused element, with the app re-proven frontmost first. Both readings come
    /// through here, so neither can quietly read an app the caller did not name.
    private func focusedElement() throws -> (AXUIElement, String) {
        let app = try requireFrontmost()
        let name = bundleID.rawValue
        let application = AXUIElementCreateApplication(app.processIdentifier)
        // A bound this code states is a bound it has to keep. An Accessibility read is a
        // synchronous call into another process, and left at the system default one read
        // of an app whose main thread is busy can outlast the whole `within` it was made
        // under - so `wait(within: .seconds(3))` would quietly take longer than three
        // seconds. [FRAMING:representation] A stated bound the code cannot hold is a map
        // that does not match its territory. Half a second is far above the 10-35 ms an
        // answer takes here and far below any budget it is polled inside.
        AXUIElementSetMessagingTimeout(application, 0.5)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let element = Self.element(focused) else { throw ScreenUnreadable.noFocus(name) }
        AXUIElementSetMessagingTimeout(element, 0.5)
        return (element, name)
    }

    /// The answer as an element, when the app answered with one. A CoreFoundation value
    /// admits no cast check, so its type id is the check. [LAW:parse-dont-validate] This
    /// command is pointed at whatever bundle id the caller names, and an app whose
    /// Accessibility implementation answers this query with something else would
    /// otherwise trap the process where it should have been refused by name.
    /// LowTalkerCore's PasteMenuItem guards the same cast the same way; 3ti.12 takes
    /// reading the screen over from both and is where the two become one.
    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Polls the focused text until `condition` holds or `limit` passes: an app paints
    /// when it paints, so the wait is on the state and the bound is the verdict.
    func wait(within limit: Duration, until condition: (String) -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < limit {
            try interrupt.check()
            if condition(try read()) { return true }
            // Far below the 10-35 ms being measured, and far above a rate that would load
            // the target app's main thread with synchronous Accessibility calls and skew
            // the number this command exists to report.
            try await Task.sleep(for: .milliseconds(2))
        }
        return condition(try read())
    }
}

enum ScreenUnreadable: Error, CustomStringConvertible {
    case noFrontmostApp
    case notRunning(String)
    /// Raising the target failed, which happens before a single report is posted. This
    /// is the only case that can promise nothing was typed, so it is the only one that
    /// says so. [LAW:types-are-the-program]
    case wouldNotComeForward(wanted: String, frontmost: String)
    /// The wrong app is in front. That is all this says, because it is thrown from the
    /// checks before typing and from the checks between keystrokes alike, and only the
    /// caller knows which. A single case claiming "nothing was typed" would be a lie
    /// half the time it fired.
    case wrongApp(wanted: String, frontmost: String)
    case noFocus(String)
    case noText(String)

    var description: String {
        switch self {
        case .noFrontmostApp: "no app is frontmost, so there is no focused element to read"
        case .notRunning(let app): "\(app) is not running, so there is nothing to type into"
        case .wouldNotComeForward(let wanted, let frontmost): "\(wanted) would not come to the front, \(frontmost) is there; nothing was typed"
        case .wrongApp(let wanted, let frontmost): "\(frontmost) is frontmost, not \(wanted)"
        case .noFocus(let app): "\(app) has no focused element; is this process allowed under Accessibility?"
        case .noText(let app): "the focused element in \(app) carries no text value"
        }
    }
}

extension String {
    /// [LAW:one-type-per-behavior] One counter serves both checks; the first character's
    /// is this with a one-character needle.
    func occurrences(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = 0
        var searched = startIndex
        while let found = self[searched...].range(of: text) {
            count += 1
            searched = found.upperBound
        }
        return count
    }
}

extension Duration {
    /// Milliseconds to a tenth, the resolution a keystroke's latency needs.
    var milliseconds: String {
        fixed(Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15, places: 1)
    }

    var microseconds: Int64 {
        components.seconds * 1_000_000 + components.attoseconds / 1_000_000_000_000
    }
}
