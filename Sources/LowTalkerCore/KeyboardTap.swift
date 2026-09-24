import Carbon.HIToolbox
import CoreGraphics
import IOKit.hidsystem

/// What a tap does about the system having switched it off for being slow to answer.
///
/// An active tap is a gate: the window server holds every keystroke in the session
/// behind this process until the callback returns, and switches the tap off when it
/// waits too long. Switching it back on is therefore a choice with the whole machine's
/// keyboard on the other side of it, and this is that choice made explicit.
///
/// [LAW:dataflow-not-control-flow] The tap always asks and always obeys; which of the
/// two happens is a value the policy above returns, not a branch the tap owns.
public enum LapseResponse: Hashable, Sendable {
    /// Switch the tap back on and keep listening.
    case rearm
    /// Leave it off. From the moment this is returned the session's keys reach the
    /// frontmost app without passing through this process, and the hotkey is gone until
    /// something starts it again. The user's keyboard outranks this app's hotkey.
    case comeDown
}

/// Why the system switched the tap off.
///
/// [LAW:types-are-the-program] Only one of these is this process's fault, and a policy
/// that counts them together would take the hotkey down for something it did not do and
/// could not have avoided - then tell the user this app was too slow, sending them after
/// the wrong thing entirely.
public enum LapseCause: Hashable, Sendable {
    /// This process did not answer inside the window server's deadline. The keys that
    /// queued behind it in the meantime were thrown away.
    case tooSlow
    /// The system switched the tap off around the user's own input. Not this process's
    /// doing, and nothing it can go faster to avoid.
    case userInput
}

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
    /// the main actor, that the system switched the tap off, when, and why; the events
    /// in between are lost, and what it answers decides whether the tap goes back on.
    /// Throws when the session refuses a tap, which is a permission matter.
    ///
    /// `chords` are what the detector above will look for. A tap that sees every key may
    /// ignore them; one that can only hear what it asked for registers exactly these.
    func install(
        listeningFor chords: Set<KeyChord>,
        handling handle: @escaping @MainActor (KeyEvent) -> HotkeyDetector.Passage,
        onLapse: @escaping @MainActor (HostTime, LapseCause) -> LapseResponse
    ) throws -> Disposal
}

public enum KeyboardTapError: Error, CustomStringConvertible {
    /// The grants were read as held and the session still would not make the tap.
    case refused
    /// The grants were not held, so no tap was asked for: creating one anyway is what makes
    /// macOS raise its own dialog, unasked, in front of whatever the person was doing.
    case notAllowed

    public var description: String {
        switch self {
        case .refused: "the session refused an event tap; allow this app under System Settings > Privacy & Security, in both Input Monitoring and Accessibility"
        case .notAllowed: "this hotkey needs Input Monitoring and Accessibility, and this app does not have both yet; allow them from Set Up in the menu, or under System Settings > Privacy & Security"
        }
    }
}

extension Modifier {
    /// The key that moves this modifier, and the bit the event's flags carry while it
    /// is held. The bits are the device-side ones from IOLLEvent.h, which tell left
    /// from right where the CoreGraphics masks do not.
    ///
    /// Public because the key code is how a modifier becomes a HID usage for the typist:
    /// derived through the one key-code table rather than tabulated a second time beside
    /// it. [LAW:one-source-of-truth]
    public var hardware: (keyCode: CGKeyCode, mask: UInt64) {
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
        // The window server stamps events in nanoseconds on the clock the machine has
        // been up on - the same one CoreAudio stamps microphone buffers with - so a
        // press and a sample are comparable without converting between two clocks.
        let time = HostTime(uptime: .nanoseconds(event.timestamp))
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
        let handle: @MainActor (KeyEvent) -> HotkeyDetector.Passage
        let onLapse: @MainActor (HostTime, LapseCause) -> LapseResponse
        var port: CFMachPort?

        init(handle: @escaping @MainActor (KeyEvent) -> HotkeyDetector.Passage, onLapse: @escaping @MainActor (HostTime, LapseCause) -> LapseResponse) {
            self.handle = handle
            self.onLapse = onLapse
        }

        /// The moment a lapse is reported with is read from the clock here rather than
        /// off the event.
        ///
        /// A key event carries a stamp the window server took from the device, which is
        /// why `KeyEvent` reads it. A `tapDisabled` event is synthesized, and nothing
        /// promises its stamp is on the uptime clock or set at all. A policy that counted
        /// lapses inside a window would quietly stop working on a stamp that never moves
        /// - every lapse landing at the same moment, the window never sliding, and the
        /// cap becoming "five lapses for the life of the tap". This callback runs at the
        /// lapse, so the clock here is the moment, and it cannot be wrong.
        /// [LAW:one-source-of-truth]
        @MainActor
        func deliver(_ event: CGEvent, type: CGEventType) -> HotkeyDetector.Passage {
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                let cause: LapseCause = type == .tapDisabledByTimeout ? .tooSlow : .userInput
                switch onLapse(.now, cause) {
                // The port is set before the tap is enabled, so a callback cannot precede it.
                case .rearm: CGEvent.tapEnable(tap: port!, enable: true)
                // Left off. Saying so is the policy's job, not this one's.
                case .comeDown: break
                }
                return .pass
            default:
                guard let key = KeyEvent(event, type: type) else { return .pass }
                return handle(key)
            }
        }
    }

    public init() {}

    /// Sees every key, so the chords are the detector's to find and not this tap's.
    public func install(
        listeningFor chords: Set<KeyChord>,
        handling handle: @escaping @MainActor (KeyEvent) -> HotkeyDetector.Passage,
        onLapse: @escaping @MainActor (HostTime, LapseCause) -> LapseResponse
    ) throws -> Disposal {
        // [LAW:single-enforcer] The one place a keyboard tap is created, so the one place that
        // makes sure creating it cannot put a system dialog on screen.
        guard EventTapAccess.held else { throw KeyboardTapError.notAllowed }
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
