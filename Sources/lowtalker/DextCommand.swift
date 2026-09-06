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
        let daemon = try DaemonConnection()
        try daemon.request(.keyboardInitialize, DaemonConnection.keyboardParameters, within: .seconds(2))
        let readyAfter = try daemon.awaitKeyboardReady(within: .seconds(2))
        print("daemon answered in \((readyAfter.answered - connecting).milliseconds) ms, keyboard ready after \((readyAfter.ready - connecting).milliseconds) ms")

        // [LAW:no-ambient-temporal-coupling] The target is stated, not discovered, and
        // every read re-checks it, so a window that steals focus mid-run is a named
        // failure rather than text delivered somewhere nobody asked for.
        let screen = TargetApp(bundleID: into)
        try await screen.raise(within: .seconds(5))
        let start = try screen.focus()
        let before = start.text
        // Which element, not just which app: a find bar accepts keystrokes as readily as
        // a document, and reads them back just as convincingly.
        print("typing into \(into.rawValue), focus is \(start.role)")

        // One character alone, so its latency is the driver's and not the queue's.
        let first = keystrokes[0]
        let firstPosted = clock.now
        try daemon.press(first)
        let firstSeen = try await screen.wait(within: .seconds(3)) { $0.occurrences(of: String(first.character)) > before.occurrences(of: String(first.character)) }
        print("first character on screen in \(into.rawValue) after \((clock.now - firstPosted).milliseconds) ms\(firstSeen ? "" : " (NEVER SEEN)")")

        // Focus is re-checked before every report, not once before the burst. A keystroke
        // is irrevocable the moment it is posted, so the window in which focus may move
        // has to be one keystroke wide; anything wider delivers the rest of the text to
        // whatever app took the front. [LAW:no-ambient-temporal-coupling]
        let restPosted = clock.now
        for keystroke in keystrokes.dropFirst() {
            try screen.requireFrontmost()
            try daemon.press(keystroke)
        }
        let acknowledged = clock.now - restPosted
        // Against a baseline, like the first character's check: an app already holding this
        // text would otherwise confirm a run that delivered nothing.
        let allSeen = try await screen.wait(within: .seconds(5)) { $0.occurrences(of: text) > before.occurrences(of: text) }
        let settled = clock.now - restPosted
        print("\(keystrokes.count) characters posted and acknowledged in \(acknowledged.milliseconds) ms, on screen after \(settled.milliseconds) ms")
        print(allSeen ? "the screen holds the text, complete and in order" : "MISMATCH: the screen holds [\(try screen.read())]")
        try daemon.request(.keyboardReset, [], within: .seconds(2))
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
    private enum FrameType: UInt8 {
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

    init() throws {
        guard FileManager.default.fileExists(atPath: Self.socketPath) else { throw DaemonError.noSocket }
        socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw DaemonError.socket("socket", errno) }
        var noSignal: Int32 = 1
        // [LAW:no-silent-failure] This is the only thing standing between a write to a
        // closed socket and SIGPIPE killing the process without a word, so a failure to
        // set it is reported rather than assumed.
        guard setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let code = errno
            close(socket)
            throw DaemonError.socket("setsockopt(SO_NOSIGPIPE)", code)
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
            let code = errno
            close(socket)
            throw DaemonError.socket("connect", code)
        }
    }

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
        try write(frame(.request, id: id, data))
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
            try write(frame(.healthCheckResponse, id: nil, []))
        case .request:
            try record(data)
            try write(frame(.response, id: id, []))
        case .response:
            try record(data)
        }
    }

    private func record(_ pairs: [UInt8]) throws {
        guard pairs.count % 2 == 0 else { throw DaemonError.malformed("a status payload of \(pairs.count) bytes, which is not pairs") }
        for index in stride(from: 0, to: pairs.count, by: 2) {
            guard let status = Status(rawValue: pairs[index]) else { throw DaemonError.malformed("status \(pairs[index]), which this was not written for") }
            self.status[status] = pairs[index + 1] != 0
        }
    }

    private func frame(_ type: FrameType, id: UInt64?, _ data: [UInt8]) -> [UInt8] {
        let requestID = id.map { id in (0..<8).reversed().map { UInt8(truncatingIfNeeded: id >> (8 * $0)) } } ?? []
        let body = [type.rawValue] + requestID + data
        let length = UInt32(body.count)
        return (0..<4).reversed().map { UInt8(truncatingIfNeeded: length >> (8 * $0)) } + body
    }

    private func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(socket, $0.baseAddress, $0.count) }
            guard written > 0 else { throw DaemonError.socket("write", errno) }
            offset += written
        }
    }

    private func readFrame(by deadline: ContinuousClock.Instant) throws -> (FrameType, UInt64, [UInt8]) {
        let header = try read(4, by: deadline)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length >= 1 else { throw DaemonError.malformed("an empty frame") }
        let body = try read(length, by: deadline)
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

    private func read(_ count: Int, by deadline: ContinuousClock.Instant) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw DaemonError.silent }
            var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            let readable = poll(&descriptor, 1, Int32(remaining.components.seconds * 1_000 + remaining.components.attoseconds / 1_000_000_000_000_000))
            guard readable >= 0 else { throw DaemonError.socket("poll", errno) }
            guard readable > 0 else { throw DaemonError.silent }
            let got = bytes[offset...].withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress, $0.count) }
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
            target.activate()
            try await Task.sleep(for: .milliseconds(100))
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID.rawValue { return }
        } while clock.now - start < limit
        throw ScreenUnreadable.wrongApp(wanted: bundleID.rawValue, frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nothing")
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
        let app = try requireFrontmost()
        let name = bundleID.rawValue
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute as CFString, &focused) == .success, let element = focused else { throw ScreenUnreadable.noFocus(name) }
        var role: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXRoleAttribute as CFString, &role)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString, &value) == .success, let text = value as? String else { throw ScreenUnreadable.noText(name) }
        return Focus(role: role as? String ?? "an element that will not name its role", text: text)
    }

    func read() throws -> String {
        try focus().text
    }

    /// Polls the focused text until `condition` holds or `limit` passes: an app paints
    /// when it paints, so the wait is on the state and the bound is the verdict.
    func wait(within limit: Duration, until condition: (String) -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < limit {
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
    case wrongApp(wanted: String, frontmost: String)
    case noFocus(String)
    case noText(String)

    var description: String {
        switch self {
        case .noFrontmostApp: "no app is frontmost, so there is no focused element to read"
        case .notRunning(let app): "\(app) is not running, so there is nothing to type into"
        case .wrongApp(let wanted, let frontmost): "\(frontmost) is frontmost, not \(wanted); nothing was typed"
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
