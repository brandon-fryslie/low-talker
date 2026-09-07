import Foundation
import Pointing

/// The pointing input report as the driver's packed `pointing_input` lays it out: a
/// 32-bit little-endian button field, then x, y, vertical wheel and horizontal wheel as
/// one signed byte each. 8 bytes, and no report id: the pointing collection is its own
/// device to the driver, unlike the keyboard whose report names its collection.
///
/// Built from the buttons that are down and the motion of this one report, and from
/// nothing else, for the reason `KeyboardReport` gives. [LAW:one-source-of-truth]
struct PointingReport {
    let buttons: UInt32
    let move: Move
    let scroll: Scroll

    init(held: Set<Button>, move: Move, scroll: Scroll) {
        buttons = held.reduce(0) { $0 | $1.bit }
        self.move = move
        self.scroll = scroll
    }

    var bytes: [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: buttons >> (8 * $0)) }
            + [move.x, move.y, scroll.vertical, scroll.horizontal].map { UInt8(bitPattern: $0.value) }
    }
}

/// The virtual mouse, spoken to in the device's own vocabulary: a button goes down, the
/// pointer moves by so many counts, the wheel rolls, and the device works out what to send.
///
/// It holds the set of buttons that are down and derives every report from that set, so
/// motion and wheel reports carry the buttons held - which is what makes a drag a button
/// down, moves, and a release, with nothing composed by the caller. The device knows only
/// deltas: where the pointer *is* is a fact of the window server, which the process that
/// can read it turns into a sequence of deltas above this seam. [LAW:one-way-deps]
///
/// **The calling process must be root**, for the reason `DaemonConnection` gives.
public final class VirtualPointing: Pointing {
    private let daemon: DaemonConnection
    private let reportTimeout: Duration
    /// The buttons the device is holding. Nothing outside this type may set it, and every
    /// report is a reading of it.
    public private(set) var buttonsDown: Set<Button> = []

    /// Over a connection the keyboard may share: pqrs's daemon keeps one keyboard and one
    /// pointing device per client connection, so the two devices of one helper ride one
    /// socket, and the daemon's `erase_client` takes both when it closes.
    public init(daemon: DaemonConnection, reportTimeout: Duration = .seconds(2)) {
        self.daemon = daemon
        self.reportTimeout = reportTimeout
    }

    /// Brings the device up and waits for the daemon's word that it is ready, in at most
    /// `limit` altogether. `pointing_initialize` carries no parameters: the driver's
    /// pointing collection has one identity, unlike the keyboard's vendor and product.
    @discardableResult
    public func start(within limit: Duration) throws -> Startup {
        try daemon.initialize(.pointingInitialize, [], until: .pointingReady, within: limit)
    }

    /// Holds `button` down.
    public func down(_ button: Button) throws {
        try post(held: buttonsDown.union([button]), move: .none, scroll: .none)
    }

    /// Every button up. Posted unconditionally, for the reason the keyboard's release is:
    /// a button the driver believes is down is a drag macOS continues into whatever the
    /// pointer crosses next.
    public func releaseAll() throws {
        try post(held: [], move: .none, scroll: .none)
    }

    /// Moves by `delta`, with whatever is held still held.
    public func move(by delta: Move) throws {
        try post(held: buttonsDown, move: delta, scroll: .none)
    }

    /// Rolls the wheel by `delta`, with whatever is held still held.
    public func scroll(by delta: Scroll) throws {
        try post(held: buttonsDown, move: .none, scroll: delta)
    }

    /// Clears the device's own state as well as this side's, for the case where the two
    /// might have drifted apart. The record is emptied on the daemon's answer and not
    /// before, for the reason `post` gives.
    public func reset() throws {
        try daemon.request(.pointingReset, by: .now + reportTimeout)
        buttonsDown.removeAll()
    }

    /// Posts the report for `held` with this report's motion, and makes `held` the record.
    ///
    /// The same bias `VirtualKeyboard.post` keeps, for the same reason: the record widens
    /// before the request and narrows only on the answer, so a request that threw after
    /// reaching the driver leaves a button `releaseAll` can still see.
    /// [LAW:dataflow-not-control-flow]
    private func post(held: Set<Button>, move: Move, scroll: Scroll) throws {
        let report = PointingReport(held: held, move: move, scroll: scroll)
        buttonsDown.formUnion(held)
        try daemon.request(.postPointingInputReport, report.bytes, by: .now + reportTimeout)
        buttonsDown = held
    }
}
