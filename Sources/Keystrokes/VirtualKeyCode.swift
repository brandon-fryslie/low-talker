public extension Usage {
    /// The HID usage a macOS virtual key code names, or nil for a key the keyboard page
    /// has no usage for.
    ///
    /// The two vocabularies for one key. macOS key codes are the ADB layout's positions
    /// and run in no order a reader can predict - A is 0, S is 1, and 5 sits between 6 and
    /// `=` - so this is transcribed rather than computed, and every row is a chance to be
    /// wrong in a way nothing downstream can notice. So no row is taken on this table's own
    /// word. The character rows are checked against the alphabet the 3ti.2 spike drove a
    /// real driver with; the modifier row against the table the hotkey already posts; and
    /// every row that types nothing - navigation, function keys, keypad, and the four
    /// stragglers Escape, Delete, Caps Lock and ISO Section - against Carbon's own key code
    /// symbols and the order the HID usage page fixes, since no layout test can reach a key
    /// that answers with no character.
    ///
    /// The keys that carry no character are here too. A chord names arrows and function
    /// keys, and the same act reaches the device the same way. [LAW:composability]
    init?(virtualKeyCode: UInt16) {
        guard let usage = Self.byVirtualKeyCode[virtualKeyCode] else { return nil }
        self = usage
    }

    private static let byVirtualKeyCode: [UInt16: Usage] = [
        // The letters, in ADB position order rather than alphabetical.
        0x00: Usage(rawValue: 0x04), // A
        0x01: Usage(rawValue: 0x16), // S
        0x02: Usage(rawValue: 0x07), // D
        0x03: Usage(rawValue: 0x09), // F
        0x04: Usage(rawValue: 0x0B), // H
        0x05: Usage(rawValue: 0x0A), // G
        0x06: Usage(rawValue: 0x1D), // Z
        0x07: Usage(rawValue: 0x1B), // X
        0x08: Usage(rawValue: 0x06), // C
        0x09: Usage(rawValue: 0x19), // V
        0x0A: Usage(rawValue: 0x64), // ISO section, the extra key on a European board
        0x0B: Usage(rawValue: 0x05), // B
        0x0C: Usage(rawValue: 0x14), // Q
        0x0D: Usage(rawValue: 0x1A), // W
        0x0E: Usage(rawValue: 0x08), // E
        0x0F: Usage(rawValue: 0x15), // R
        0x10: Usage(rawValue: 0x1C), // Y
        0x11: Usage(rawValue: 0x17), // T
        0x1F: Usage(rawValue: 0x12), // O
        0x20: Usage(rawValue: 0x18), // U
        0x22: Usage(rawValue: 0x0C), // I
        0x23: Usage(rawValue: 0x13), // P
        0x25: Usage(rawValue: 0x0F), // L
        0x26: Usage(rawValue: 0x0D), // J
        0x28: Usage(rawValue: 0x0E), // K
        0x2D: Usage(rawValue: 0x11), // N
        0x2E: Usage(rawValue: 0x10), // M
        // The digit row, where 5 and 6 are the transposition this invites.
        0x12: Usage(rawValue: 0x1E), // 1
        0x13: Usage(rawValue: 0x1F), // 2
        0x14: Usage(rawValue: 0x20), // 3
        0x15: Usage(rawValue: 0x21), // 4
        0x16: Usage(rawValue: 0x23), // 6
        0x17: Usage(rawValue: 0x22), // 5
        0x19: Usage(rawValue: 0x26), // 9
        0x1A: Usage(rawValue: 0x24), // 7
        0x1C: Usage(rawValue: 0x25), // 8
        0x1D: Usage(rawValue: 0x27), // 0
        // Punctuation.
        0x18: Usage(rawValue: 0x2E), // =
        0x1B: Usage(rawValue: 0x2D), // -
        0x1E: Usage(rawValue: 0x30), // ]
        0x21: Usage(rawValue: 0x2F), // [
        0x27: Usage(rawValue: 0x34), // '
        0x29: Usage(rawValue: 0x33), // ;
        0x2A: Usage(rawValue: 0x31), // \
        0x2B: Usage(rawValue: 0x36), // ,
        0x2C: Usage(rawValue: 0x38), // /
        0x2F: Usage(rawValue: 0x37), // .
        0x32: Usage(rawValue: 0x35), // `
        // Whitespace and the keys that edit rather than type.
        0x24: .returnKey,
        0x30: .tab,
        0x31: .space,
        0x33: .delete,
        0x35: .escape,
        0x39: Usage(rawValue: 0x39), // caps lock
        // The modifiers, which are keys like any other to the device.
        0x37: .leftCommand,
        0x38: .leftShift,
        0x3A: .leftOption,
        0x3B: .leftControl,
        0x36: .rightCommand,
        0x3C: .rightShift,
        0x3D: .rightOption,
        0x3E: .rightControl,
        // Navigation.
        0x72: Usage(rawValue: 0x49), // help / insert
        0x73: Usage(rawValue: 0x4A), // home
        0x74: Usage(rawValue: 0x4B), // page up
        0x75: Usage(rawValue: 0x4C), // forward delete
        0x77: Usage(rawValue: 0x4D), // end
        0x79: Usage(rawValue: 0x4E), // page down
        0x7B: Usage(rawValue: 0x50), // left
        0x7C: Usage(rawValue: 0x4F), // right
        0x7D: Usage(rawValue: 0x51), // down
        0x7E: Usage(rawValue: 0x52), // up
        // The function row, also in no order.
        0x7A: Usage(rawValue: 0x3A), // F1
        0x78: Usage(rawValue: 0x3B), // F2
        0x63: Usage(rawValue: 0x3C), // F3
        0x76: Usage(rawValue: 0x3D), // F4
        0x60: Usage(rawValue: 0x3E), // F5
        0x61: Usage(rawValue: 0x3F), // F6
        0x62: Usage(rawValue: 0x40), // F7
        0x64: Usage(rawValue: 0x41), // F8
        0x65: Usage(rawValue: 0x42), // F9
        0x6D: Usage(rawValue: 0x43), // F10
        0x67: Usage(rawValue: 0x44), // F11
        0x6F: Usage(rawValue: 0x45), // F12
        0x69: Usage(rawValue: 0x68), // F13
        0x6B: Usage(rawValue: 0x69), // F14
        0x71: Usage(rawValue: 0x6A), // F15
        0x6A: Usage(rawValue: 0x6B), // F16
        0x40: Usage(rawValue: 0x6C), // F17
        0x4F: Usage(rawValue: 0x6D), // F18
        0x50: Usage(rawValue: 0x6E), // F19
        0x5A: Usage(rawValue: 0x6F), // F20
        // The keypad, which types digits of its own and is a different key for each.
        0x52: Usage(rawValue: 0x62), // keypad 0
        0x53: Usage(rawValue: 0x59), // keypad 1
        0x54: Usage(rawValue: 0x5A), // keypad 2
        0x55: Usage(rawValue: 0x5B), // keypad 3
        0x56: Usage(rawValue: 0x5C), // keypad 4
        0x57: Usage(rawValue: 0x5D), // keypad 5
        0x58: Usage(rawValue: 0x5E), // keypad 6
        0x59: Usage(rawValue: 0x5F), // keypad 7
        0x5B: Usage(rawValue: 0x60), // keypad 8
        0x5C: Usage(rawValue: 0x61), // keypad 9
        0x41: Usage(rawValue: 0x63), // keypad .
        0x43: Usage(rawValue: 0x55), // keypad *
        0x45: Usage(rawValue: 0x57), // keypad +
        0x47: Usage(rawValue: 0x53), // keypad clear / num lock
        0x4B: Usage(rawValue: 0x54), // keypad /
        0x4C: Usage(rawValue: 0x58), // keypad enter
        0x4E: Usage(rawValue: 0x56), // keypad -
        0x51: Usage(rawValue: 0x67), // keypad =
    ]
}
