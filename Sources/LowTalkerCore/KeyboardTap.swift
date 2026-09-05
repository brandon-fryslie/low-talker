import Carbon.HIToolbox
import CoreGraphics
import IOKit.hidsystem

/// A place in front of every keyboard event in the login session, where each one is
/// seen before the frontmost app and can be kept from it.
///
/// [LAW:effects-at-boundaries] The event tap is an effect against the window server,
/// and the permissions it needs are the user's to grant. It sits behind this seam so
/// the press detection above it runs in tests against a keyboard a test types on.
@MainActor
public protocol KeyboardTap {
    /// Puts `handle` in front of the session's keyboard events, on the main actor;
    /// what it returns is what the frontmost app gets. `onLapse` reports, also on
    /// the main actor, that the system had switched the tap off and it has been
    /// switched back on; the events in between are lost.
    /// Throws when the session refuses a tap, which is a permission matter.
    func install(
        handling handle: @escaping @MainActor (KeyEvent) -> HotkeyDetector.Delivery,
        onLapse: @escaping @MainActor () -> Void
    ) throws -> Disposal
}

public enum KeyboardTapError: Error, CustomStringConvertible {
    case refused

    public var description: String {
        switch self {
        case .refused: "the session refused an event tap; allow this app under System Settings > Privacy & Security, in both Input Monitoring and Accessibility"
        }
    }
}

extension Modifier {
    /// The key that moves this modifier, and the bit the event's flags carry while it
    /// is held. The bits are the device-side ones from IOLLEvent.h, which tell left
    /// from right where the CoreGraphics masks do not.
    var hardware: (keyCode: CGKeyCode, mask: UInt64) {
        switch self {
        case .leftShift: (CGKeyCode(kVK_Shift), UInt64(NX_DEVICELSHIFTKEYMASK))
        case .rightShift: (CGKeyCode(kVK_RightShift), UInt64(NX_DEVICERSHIFTKEYMASK))
        case .leftControl: (CGKeyCode(kVK_Control), UInt64(NX_DEVICELCTLKEYMASK))
        case .rightControl: (CGKeyCode(kVK_RightControl), UInt64(NX_DEVICERCTLKEYMASK))
        case .leftOption: (CGKeyCode(kVK_Option), UInt64(NX_DEVICELALTKEYMASK))
        case .rightOption: (CGKeyCode(kVK_RightOption), UInt64(NX_DEVICERALTKEYMASK))
        case .leftCommand: (CGKeyCode(kVK_Command), UInt64(NX_DEVICELCMDKEYMASK))
        case .rightCommand: (CGKeyCode(kVK_RightCommand), UInt64(NX_DEVICERCMDKEYMASK))
        // Also set on the arrow, Home, End, Page and Forward Delete keys, Fn held or
        // not; telling the Fn key itself apart is low-hotkey-a6m.3.
        case .function: (CGKeyCode(kVK_Function), UInt64(NX_SECONDARYFNMASK))
        }
    }

    init?(keyCode: CGKeyCode) {
        guard let modifier = Self.allCases.first(where: { $0.hardware.keyCode == keyCode }) else { return nil }
        self = modifier
    }

    /// The modifiers an event's flags say are held.
    static func held(in flags: CGEventFlags) -> Set<Modifier> {
        Set(allCases.filter { flags.rawValue & $0.hardware.mask != 0 })
    }
}

extension KeyEvent {
    /// [LAW:parse-dont-validate] The one place a window server event becomes a key
    /// event. Nil is an event about a key with no name here (Caps Lock, a media key),
    /// which the frontmost app gets untouched.
    public init?(_ event: CGEvent, type: CGEventType) {
        // The window server keeps the key code in 16 bits, so this cannot trap on a
        // code any process posts.
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = Modifier.held(in: event.flags)
        let time = Duration.nanoseconds(event.timestamp)
        switch type {
        case .flagsChanged:
            guard let modifier = Modifier(keyCode: keyCode) else { return nil }
            self.init(key: .modifier(modifier), direction: modifiers.contains(modifier) ? .down : .up, modifiers: modifiers, time: time)
        case .keyDown:
            self.init(key: .key(Key(rawValue: keyCode)), direction: .down, modifiers: modifiers, time: time)
        case .keyUp:
            self.init(key: .key(Key(rawValue: keyCode)), direction: .up, modifiers: modifiers, time: time)
        default:
            return nil
        }
    }
}

public struct SystemKeyboardTap: KeyboardTap {
    /// What the C callback reaches through its context pointer. It also keeps the
    /// port, which the callback needs to switch the tap back on.
    private final class Installed {
        let handle: @MainActor (KeyEvent) -> HotkeyDetector.Delivery
        let onLapse: @MainActor () -> Void
        var port: CFMachPort?

        init(handle: @escaping @MainActor (KeyEvent) -> HotkeyDetector.Delivery, onLapse: @escaping @MainActor () -> Void) {
            self.handle = handle
            self.onLapse = onLapse
        }

        @MainActor
        func deliver(_ event: CGEvent, type: CGEventType) -> HotkeyDetector.Delivery {
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                // The port is set before the tap is enabled, so a callback cannot precede it.
                CGEvent.tapEnable(tap: port!, enable: true)
                onLapse()
                return .pass
            default:
                guard let key = KeyEvent(event, type: type) else { return .pass }
                return handle(key)
            }
        }
    }

    public init() {}

    public func install(
        handling handle: @escaping @MainActor (KeyEvent) -> HotkeyDetector.Delivery,
        onLapse: @escaping @MainActor () -> Void
    ) throws -> Disposal {
        let installed = Unmanaged.passRetained(Installed(handle: handle, onLapse: onLapse))
        let interest: CGEventMask = [CGEventType.flagsChanged, .keyDown, .keyUp].reduce(0) { $0 | 1 << $1.rawValue }
        // Scheduled on the main run loop, so the callback runs on the main actor.
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: interest,
            callback: { _, type, event, context in
                let installed = Unmanaged<Installed>.fromOpaque(context!).takeUnretainedValue()
                switch MainActor.assumeIsolated({ installed.deliver(event, type: type) }) {
                case .pass: return Unmanaged.passUnretained(event)
                case .swallow: return nil
                }
            },
            userInfo: installed.toOpaque()
        ) else {
            installed.release()
            throw KeyboardTapError.refused
        }
        installed.takeUnretainedValue().port = port
        guard let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            preconditionFailure("CoreFoundation refused a run loop source for the event tap it just created")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return {
            CGEvent.tapEnable(tap: port, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFMachPortInvalidate(port)
            installed.release()
        }
    }
}
