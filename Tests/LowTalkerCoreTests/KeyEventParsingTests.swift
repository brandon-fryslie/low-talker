import Carbon.HIToolbox
import CoreGraphics
import IOKit.hidsystem
import LowTalkerCore
import Testing

/// The device-side flag bits from IOLLEvent.h, as the window server sets them.
private let rightOptionBits: UInt64 = 0x40
private let leftShiftBits: UInt64 = 0x02

private func event(type: CGEventType, keyCode: CGKeyCode, flags: UInt64, at nanoseconds: UInt64 = 0) throws -> CGEvent {
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: type == .keyDown))
    event.type = type
    event.flags = CGEventFlags(rawValue: flags)
    event.timestamp = nanoseconds
    return event
}

@Suite struct KeyEventParsingTests {
    /// A modifier's own flags-changed event says which way it moved.
    @Test func aModifierComingDownIsADownWithTheModifiersHeld() throws {
        let parsed = KeyEvent(try event(type: .flagsChanged, keyCode: 61, flags: CGEventFlags.maskAlternate.rawValue | rightOptionBits, at: 1_500), type: .flagsChanged)
        #expect(parsed == KeyEvent(key: .modifier(.rightOption), direction: .down, modifiers: [.rightOption], time: .nanoseconds(1_500)))
    }

    @Test func aModifierGoingUpIsAnUpWithoutIt() throws {
        let parsed = KeyEvent(try event(type: .flagsChanged, keyCode: 61, flags: CGEventFlags.maskShift.rawValue | leftShiftBits), type: .flagsChanged)
        #expect(parsed == KeyEvent(key: .modifier(.rightOption), direction: .up, modifiers: [.leftShift], time: .zero))
    }

    @Test func keysCarryTheModifiersHeldWithThem() throws {
        let down = KeyEvent(try event(type: .keyDown, keyCode: 0, flags: CGEventFlags.maskAlternate.rawValue | rightOptionBits), type: .keyDown)
        #expect(down == KeyEvent(key: .key(Key(rawValue: 0)), direction: .down, modifiers: [.rightOption], time: .zero))
        let up = KeyEvent(try event(type: .keyUp, keyCode: 0, flags: 0), type: .keyUp)
        #expect(up == KeyEvent(key: .key(Key(rawValue: 0)), direction: .up, modifiers: [], time: .zero))
    }

    /// Every modifier, stated against the Carbon key code and the IOLLEvent device bit
    /// the window server uses for it, so a side swapped in the table is caught.
    @Test(arguments: [
        (Modifier.leftShift, kVK_Shift, NX_DEVICELSHIFTKEYMASK),
        (.rightShift, kVK_RightShift, NX_DEVICERSHIFTKEYMASK),
        (.leftControl, kVK_Control, NX_DEVICELCTLKEYMASK),
        (.rightControl, kVK_RightControl, NX_DEVICERCTLKEYMASK),
        (.leftOption, kVK_Option, NX_DEVICELALTKEYMASK),
        (.rightOption, kVK_RightOption, NX_DEVICERALTKEYMASK),
        (.leftCommand, kVK_Command, NX_DEVICELCMDKEYMASK),
        (.rightCommand, kVK_RightCommand, NX_DEVICERCMDKEYMASK),
        (.function, kVK_Function, NX_SECONDARYFNMASK),
    ])
    func eachModifierIsToldBySideFromItsKeyCodeAndDeviceBit(modifier: Modifier, keyCode: Int, deviceBit: Int32) throws {
        let parsed = KeyEvent(try event(type: .flagsChanged, keyCode: CGKeyCode(keyCode), flags: UInt64(deviceBit)), type: .flagsChanged)
        #expect(parsed == KeyEvent(key: .modifier(modifier), direction: .down, modifiers: [modifier], time: .zero))
    }

    @Test func modifiersHeldTogetherAreAllReported() throws {
        let parsed = KeyEvent(try event(type: .flagsChanged, keyCode: CGKeyCode(kVK_Shift), flags: UInt64(NX_DEVICELSHIFTKEYMASK | NX_DEVICERALTKEYMASK)), type: .flagsChanged)
        #expect(parsed == KeyEvent(key: .modifier(.leftShift), direction: .down, modifiers: [.leftShift, .rightOption], time: .zero))
    }

    /// Any process can post an event with a key code beyond 16 bits; the parse must
    /// not trap on it. (The window server keeps the field to 16 bits, so it reads
    /// back as a key code.)
    @Test func aKeyCodePostedBeyondSixteenBitsDoesNotTrap() throws {
        let posted = try event(type: .keyDown, keyCode: 0, flags: 0)
        posted.setIntegerValueField(.keyboardEventKeycode, value: 1 << 40)
        #expect(KeyEvent(posted, type: .keyDown)?.key == .key(Key(rawValue: 0)))
    }

    /// Caps Lock changes flags too, but is no chord key; the app gets it untouched.
    @Test func aModifierWithNoNameHereIsNotAKeyEvent() throws {
        #expect(KeyEvent(try event(type: .flagsChanged, keyCode: 57, flags: CGEventFlags.maskAlphaShift.rawValue), type: .flagsChanged) == nil)
    }
}
