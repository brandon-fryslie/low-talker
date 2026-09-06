import Foundation

/// A key on the virtual keyboard, as the device names it: a usage from HID usage page
/// 0x07. Modifiers are usages like any other key - 0xE0 through 0xE7 - and nothing here
/// treats them as a separate kind of thing.
public struct Usage: RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static func < (a: Usage, b: Usage) -> Bool { a.rawValue < b.rawValue }

    /// The bit this usage carries in a report's modifier byte, when it is one of the
    /// eight that do. Derived from the usage rather than tabulated beside it: the eight
    /// modifier usages run in the same order as their bits, so the bit IS the usage seen
    /// another way. [LAW:one-source-of-truth] The spike kept the two as separate
    /// constants, which is one edit away from a shift key that types a control character.
    var modifierBit: UInt8? {
        guard (0xE0...0xE7).contains(rawValue) else { return nil }
        return UInt8(1 << (rawValue - 0xE0))
    }
}

public extension Usage {
    static let leftControl = Usage(rawValue: 0xE0)
    static let leftShift = Usage(rawValue: 0xE1)
    static let leftOption = Usage(rawValue: 0xE2)
    static let leftCommand = Usage(rawValue: 0xE3)
    static let rightControl = Usage(rawValue: 0xE4)
    static let rightShift = Usage(rawValue: 0xE5)
    static let rightOption = Usage(rawValue: 0xE6)
    static let rightCommand = Usage(rawValue: 0xE7)
}

/// The keyboard input report as the driver's packed `keyboard_input` lays it out: report
/// id 1, one byte of modifier bits, one reserved byte, then 32 little-endian usages for
/// the keys held. 67 bytes.
///
/// It is built from the keys that are down and from nothing else, and no caller builds
/// one. [LAW:one-source-of-truth] A report a caller could compose is a report that can
/// disagree with what the device is holding, and that disagreement has one shape: a key
/// the driver believes is down that nobody remembers pressing, which macOS then repeats.
struct KeyboardReport {
    /// A report carries at most this many non-modifier usages; the field is fixed width.
    static let capacity = 32

    let modifiers: UInt8
    let usages: [UInt16]

    init(held: Set<Usage>) throws {
        var modifiers: UInt8 = 0
        var usages: [UInt16] = []
        // Sorted so one set of held keys has one encoding: a report that varies with a
        // hash seed is a report no test can pin and no capture can be compared against.
        for usage in held.sorted() {
            if let bit = usage.modifierBit { modifiers |= bit } else { usages.append(usage.rawValue) }
        }
        guard usages.count <= Self.capacity else { throw TooManyKeys(held: usages.count) }
        self.modifiers = modifiers
        self.usages = usages
    }

    var bytes: [UInt8] {
        let padded = usages + Array(repeating: 0, count: Self.capacity - usages.count)
        return [1, modifiers, 0] + padded.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
    }
}

public struct TooManyKeys: Error, CustomStringConvertible {
    public let held: Int
    public var description: String { "\(held) keys are down, and one HID keyboard report carries \(KeyboardReport.capacity)" }
}

/// The virtual keyboard, spoken to in the device's own vocabulary: a usage goes down, a
/// usage comes up, and the device works out what to send.
///
/// It holds the set of keys that are down and derives every report from that set, so the
/// caller never composes one and the two can never disagree. What a caller decides is
/// *when* - this type posts a report and waits for the daemon's answer, and nothing here
/// paces a burst, because the pacing a burst needs is not a fact about the device.
///
/// **The calling process must be root**, for the reason `DaemonConnection` gives.
public final class VirtualKeyboard {
    /// pqrs's own defaults for the virtual keyboard, three uint64 in this order. All
    /// three are `strong_typedef`s over `uint64_t`, so the payload is 24 bytes; the
    /// reasonable-looking reading - two 16-bit ids and a byte - is five bytes long, well
    /// formed, and initializes a device that is not the one asked for.
    static let parameters: [UInt8] = [0x16c0, 0x27db, 0].flatMap { (value: UInt64) in (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }

    private let daemon: DaemonConnection
    private let reportTimeout: Duration
    /// The keys the device is holding. Nothing outside this type may set it, and every
    /// report is a reading of it.
    public private(set) var keysDown: Set<Usage> = []

    /// Connects to the daemon and takes nothing else on faith. The device is not up until
    /// `start` says so.
    public convenience init(reportTimeout: Duration = .seconds(2)) throws {
        self.init(daemon: try DaemonConnection(), reportTimeout: reportTimeout)
    }

    init(daemon: DaemonConnection, reportTimeout: Duration = .seconds(2)) {
        self.daemon = daemon
        self.reportTimeout = reportTimeout
    }

    public struct Startup: Sendable, Equatable {
        /// How long the daemon took to answer `keyboard_initialize`.
        public let answered: Duration
        /// How long until it said the keyboard was ready.
        public let ready: Duration
    }

    /// Brings the device up and waits for the daemon's word that it is ready, in at most
    /// `limit` altogether.
    ///
    /// Expect close to a second of that even on a device that came up at once: the daemon
    /// asks the driver whether the keyboard is ready on a one-second timer, so readiness
    /// is discovered on the next tick rather than when it happened. The number is pqrs's
    /// poll interval, not the hardware, and it is the reason a connection is meant to be
    /// held open rather than made per insert - a caller that connects for each insert
    /// pays it every time.
    @discardableResult
    public func start(within limit: Duration) throws -> Startup {
        let began = ContinuousClock.now
        let deadline = began + limit
        try daemon.request(.keyboardInitialize, Self.parameters, by: deadline)
        // Taken here because `request` returns on the daemon's answer to it. Timing the
        // first frame of the readiness wait instead - as this did, and the spike before
        // it - reports the first status push under a name that says the daemon had not
        // spoken yet, when answering the request is exactly what it just did.
        let answered = ContinuousClock.now
        try daemon.awaitKeyboardReady(by: deadline)
        return Startup(answered: answered - began, ready: ContinuousClock.now - began)
    }

    /// Holds `usage` down.
    public func down(_ usage: Usage) throws {
        try post(keysDown.union([usage]))
    }

    public func up(_ usage: Usage) throws {
        try post(keysDown.subtracting([usage]))
    }

    /// Every key up, which is what a report of nothing held says. This is the line between
    /// a run that ends and a key the driver goes on reporting for macOS to repeat, so it
    /// posts unconditionally rather than only when something is recorded as down.
    public func releaseAll() throws {
        try post([])
    }

    /// Clears the device's own state as well as this side's. `keyboardReset` is what the
    /// daemon offers for the case where the two might have drifted apart. The record is
    /// emptied on the daemon's answer and not before, for the reason `post` gives.
    public func reset() throws {
        try daemon.request(.keyboardReset, by: .now + reportTimeout)
        keysDown.removeAll()
    }

    /// Posts the report for `held` and makes it the record.
    ///
    /// `keysDown` may say a key is held that is not; it may never say a key is up that is.
    /// So the record widens before the request and narrows only on the answer to it: a
    /// request that throws may still have reached the driver, and a record that already
    /// forgot the key is one `releaseAll` cannot get back up. A press and a release keep
    /// that one bias between them rather than each choosing an order.
    /// [LAW:dataflow-not-control-flow]
    ///
    /// The report is built first because `TooManyKeys` is this side refusing with nothing
    /// on the wire - the driver did not see that key, and a record that claims otherwise
    /// re-encodes the same over-capacity set and throws again on every later post.
    private func post(_ held: Set<Usage>) throws {
        let report = try KeyboardReport(held: held)
        keysDown.formUnion(held)
        try daemon.request(.postKeyboardInputReport, report.bytes, by: .now + reportTimeout)
        keysDown = held
    }
}
