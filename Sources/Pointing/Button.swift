/// A mouse button, by the number the device gives it: 1 through 32, the width of the
/// button field in a pointing report. Left is 1, right is 2 and middle is 3, as HID
/// numbers them.
///
/// This module is the seam between deciding where to click and clicking, so it holds
/// the vocabulary and nothing else - no socket, no window server. Both ends need these
/// names and neither should have to link the other to say them. [LAW:one-way-deps]
public struct Button: RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: UInt8

    /// The 32 the report has a bit for, and no other. [LAW:parse-dont-validate] A button
    /// this refuses never reaches a report, so no report has to wonder what bit 33 is.
    public init?(rawValue: UInt8) {
        guard (1...32).contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public static let left = Button(rawValue: 1)!
    public static let right = Button(rawValue: 2)!
    public static let middle = Button(rawValue: 3)!

    /// The bit this button sets in the report's 32-bit button field: button n is bit
    /// n - 1. Derived from the number rather than tabulated beside it, the way a modifier
    /// usage derives its bit. [LAW:one-source-of-truth]
    public var bit: UInt32 { 1 << UInt32(rawValue - 1) }

    public static func < (a: Button, b: Button) -> Bool { a.rawValue < b.rawValue }
}
