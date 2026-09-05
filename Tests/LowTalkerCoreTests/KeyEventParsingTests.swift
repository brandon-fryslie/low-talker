import CoreGraphics
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

    /// Caps Lock changes flags too, but is no chord key; the app gets it untouched.
    @Test func aModifierWithNoNameHereIsNotAKeyEvent() throws {
        #expect(KeyEvent(try event(type: .flagsChanged, keyCode: 57, flags: CGEventFlags.maskAlphaShift.rawValue), type: .flagsChanged) == nil)
    }
}
