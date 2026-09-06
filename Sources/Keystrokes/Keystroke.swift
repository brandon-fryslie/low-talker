/// The modifiers held while a key is pressed, as the eight bits of a HID report's
/// modifier byte.
///
/// The raw value is that byte, so the device does not translate this into anything: the
/// set and the byte are one value, and `Usage.modifierBit` is the single expression that
/// relates a modifier usage to its bit. [LAW:one-source-of-truth]
///
/// Both sides are named because both are asked for. A keyboard layout does not care which
/// shift types an uppercase letter and this lowers it to the left one; a chord read off
/// the event tap says Right Option and means it, and replaying it as Left Option would
/// replay a different chord.
public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let leftControl = Modifiers(rawValue: 1 << 0)
    public static let leftShift = Modifiers(rawValue: 1 << 1)
    public static let leftOption = Modifiers(rawValue: 1 << 2)
    public static let leftCommand = Modifiers(rawValue: 1 << 3)
    public static let rightControl = Modifiers(rawValue: 1 << 4)
    public static let rightShift = Modifiers(rawValue: 1 << 5)
    public static let rightOption = Modifiers(rawValue: 1 << 6)
    public static let rightCommand = Modifiers(rawValue: 1 << 7)

    /// A usage that is not one of the eight contributes nothing, which is what it means
    /// for a modifier set: there is no bit for it to set. [LAW:no-defensive-null-guards]
    public init(_ usages: some Sequence<Usage>) {
        self.init(rawValue: usages.compactMap(\.modifierBit).reduce(0, |))
    }

    /// The usages these bits stand for, in the order the bits run.
    public var usages: [Usage] {
        (0..<8).compactMap { rawValue & (1 << $0) == 0 ? nil : Usage(rawValue: 0xE0 + UInt16($0)) }
    }
}

/// One key pressed with some modifiers held: what a layout says a character costs, and
/// what a chord says a shortcut is.
///
/// [LAW:one-type-per-behavior] They are the same act to the device, so they are the same
/// type here, and the path from either to a report is one path.
public struct Keystroke: Hashable, Sendable {
    public let usage: Usage
    public let modifiers: Modifiers

    public init(_ usage: Usage, _ modifiers: Modifiers = []) {
        self.usage = usage
        self.modifiers = modifiers
    }
}
