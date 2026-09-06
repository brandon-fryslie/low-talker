/// A HID keyboard usage: which key, in the vocabulary the device speaks.
///
/// This module is the seam between deciding what to type and typing it, so it holds the
/// vocabulary and nothing else - no socket, no Carbon, no layout. Both ends need these
/// names and neither should have to link the other to say them. [LAW:one-way-deps]
public struct Usage: RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static func < (a: Usage, b: Usage) -> Bool { a.rawValue < b.rawValue }

    /// The bit this usage carries in a report's modifier byte, when it is one of the
    /// eight that do. Derived from the usage rather than tabulated beside it: the eight
    /// modifier usages run in the same order as their bits, so the bit IS the usage seen
    /// another way. [LAW:one-source-of-truth] The spike kept the two as separate
    /// constants, which is one edit away from a shift key that types a control character.
    public var modifierBit: UInt8? {
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

    /// Keys that carry no character, named because a chord names them.
    static let returnKey = Usage(rawValue: 0x28)
    static let escape = Usage(rawValue: 0x29)
    static let delete = Usage(rawValue: 0x2A)
    static let tab = Usage(rawValue: 0x2B)
    static let space = Usage(rawValue: 0x2C)
}
