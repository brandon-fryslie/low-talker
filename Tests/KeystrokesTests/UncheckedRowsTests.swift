import Carbon.HIToolbox
import Testing
@testable import Keystrokes

/// The rows of the key code table that type no character, checked against the two things
/// they were transcribed from rather than against themselves.
///
/// The character rows are proven elsewhere - by the alphabet the 3ti.2 spike drove a real
/// driver with - and the modifier row by the table the hotkey already uses. These rows had
/// nothing: `UCKeyTranslate` answers empty for every one of them, so no layout test can
/// reach them, and a transposed usage among the sixty-odd entries here would sit unnoticed
/// until something pressed an arrow key and got a keypad digit.
///
/// Both halves of each row come from outside the table. The key code is Carbon's own
/// symbol, which is where the number was transcribed from; the usage is computed from the
/// start of its block in the HID usage tables, where these keys are contiguous and in an
/// order the spec fixes. Neither side reads the literals under test. [FRAMING:representation]
@Suite struct UncheckedRowsTests {
    private func expect(_ keyCode: Int, _ usage: UInt16, _ name: String) {
        #expect(Usage(virtualKeyCode: UInt16(keyCode)) == Usage(rawValue: usage),
                "\(name): key code \(keyCode) should be usage \(String(usage, radix: 16))")
    }

    /// F1 through F12 are contiguous from 0x3A, and F13 starts a second block at 0x68 -
    /// the one place in these rows where the usage page is not one run, and so the place a
    /// table written by counting upwards would go wrong.
    @Test func theFunctionRowIsWhereTheUsagePageSaysItIs() {
        let lower = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (index, code) in lower.enumerated() { expect(code, UInt16(0x3A + index), "F\(index + 1)") }
        let upper = [kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (index, code) in upper.enumerated() { expect(code, UInt16(0x68 + index), "F\(index + 13)") }
    }

    /// The arrows are the one block the spec orders against intuition - right before left,
    /// down before up - which is exactly the kind of thing a transcription reorders into
    /// something sensible and wrong.
    @Test func theArrowsAreInTheSpecsOrderAndNotAlphabetsOrScreens() {
        for (index, code) in [kVK_RightArrow, kVK_LeftArrow, kVK_DownArrow, kVK_UpArrow].enumerated() {
            expect(code, UInt16(0x4F + index), "arrow \(index)")
        }
    }

    /// Insert, Home, PageUp, ForwardDelete, End, PageDown, contiguous from 0x49. macOS has
    /// no Insert key and names its place Help, which is the same key code.
    @Test func theNavigationClusterRunsInTheSpecsOrder() {
        for (index, code) in [kVK_Help, kVK_Home, kVK_PageUp, kVK_ForwardDelete, kVK_End, kVK_PageDown].enumerated() {
            expect(code, UInt16(0x49 + index), "navigation \(index)")
        }
    }

    /// The keypad digits run 1 through 9 and *then* 0, which is the order of the keys under
    /// a hand and not the order of the numbers - the transposition this row invites.
    @Test func theKeypadDigitsRunOneThroughNineBeforeZero() {
        let digits = [kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
                      kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9]
        for (index, code) in digits.enumerated() { expect(code, UInt16(0x59 + index), "keypad \(index + 1)") }
        expect(kVK_ANSI_Keypad0, 0x62, "keypad 0")
        expect(kVK_ANSI_KeypadDecimal, 0x63, "keypad decimal")
    }

    /// The four that belong to no block and so are easiest to leave out of one. Escape and
    /// Delete type no character, Caps Lock types nothing at all, and ISO Section is the
    /// extra key on a European board - the one entry here whose key code and usage differ,
    /// so a transposition in it could not be caught by the two numbers coinciding.
    @Test func theKeysThatBelongToNoBlockAreThereToo() {
        expect(kVK_Escape, 0x29, "escape")
        expect(kVK_Delete, 0x2A, "delete")
        expect(kVK_CapsLock, 0x39, "caps lock")
        expect(kVK_ISO_Section, 0x64, "ISO section")
    }

    /// The operators, which the spec runs divide, multiply, minus, plus, enter from 0x54 -
    /// not the order they sit in on any keypad, and not the order a reader would guess.
    @Test func theKeypadOperatorsRunInTheSpecsOrderAndNotTheKeyboardsLayout() {
        let operators = [kVK_ANSI_KeypadDivide, kVK_ANSI_KeypadMultiply, kVK_ANSI_KeypadMinus,
                         kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadEnter]
        for (index, code) in operators.enumerated() { expect(code, UInt16(0x54 + index), "keypad operator \(index)") }
        expect(kVK_ANSI_KeypadClear, 0x53, "keypad clear")
        expect(kVK_ANSI_KeypadEquals, 0x67, "keypad equals")
    }
}
