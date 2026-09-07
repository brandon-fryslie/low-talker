/// One axis of one report's motion, in the counts the device's descriptor bounds to
/// -127 through 127.
///
/// An `Int8` admits -128, which the descriptor's logical minimum does not, so the wire's
/// own type is one value too wide. This is the type that is exactly as wide as the
/// report: made by clamping, where a caller has a distance to cover and will send the
/// rest next report, or exactly, where a value arrived over the wire and one past the
/// edge is refused rather than folded. [LAW:types-are-the-program]
public struct Count: Hashable, Sendable {
    public static let limit = 127
    public let value: Int8

    /// The nearest count to `value`: itself inside the limit, the limit outside it.
    public init(clamping value: Int) {
        self.value = Int8(max(-Self.limit, min(Self.limit, value)))
    }

    /// `value` when the descriptor admits it, nil for the one `Int8` it does not.
    public init?(exactly value: Int8) {
        guard value >= -Self.limit else { return nil }
        self.value = value
    }

    public static let zero = Count(clamping: 0)
}

/// One report's worth of pointer motion, relative: x grows to the right and y grows
/// downward, as the screen's coordinates do.
public struct Move: Hashable, Sendable {
    public let x: Count
    public let y: Count

    public init(x: Count, y: Count) {
        self.x = x
        self.y = y
    }

    public static let none = Move(x: .zero, y: .zero)
}

/// One report's worth of wheel: `vertical` positive rolls the wheel away from the hand,
/// which scrolls content up, and `horizontal` positive pans right.
public struct Scroll: Hashable, Sendable {
    public let vertical: Count
    public let horizontal: Count

    public init(vertical: Count, horizontal: Count) {
        self.vertical = vertical
        self.horizontal = horizontal
    }

    public static let none = Scroll(vertical: .zero, horizontal: .zero)
}

/// Something that holds buttons down, lets them all go, and moves.
///
/// The acts a HID mouse performs, and the whole of what has to be true of a thing for a
/// click to land on it. What is on the other side - the driver in this process, or a root
/// daemon across an XPC boundary - is not a fact anything above here needs, which is what
/// lets the same clicking code run under `sudo` against the device and unprivileged
/// against the helper. [LAW:composability]
///
/// There is no `up(_:)`, for the reason `KeyPress` gives: the device derives every report
/// from its own set of held buttons, and a caller releasing one at a time would be
/// deciding what the device is holding. Releasing everything is the act that cannot
/// disagree. [LAW:one-source-of-truth] Motion carries the buttons that are held, so a
/// drag is a button down, moves, and a release.
public protocol Pointing {
    func down(_ button: Button) throws
    func releaseAll() throws
    func move(by delta: Move) throws
    func scroll(by delta: Scroll) throws
}
