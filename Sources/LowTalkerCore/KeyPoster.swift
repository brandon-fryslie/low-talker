import CoreGraphics

/// Presses a chord in the login session as if the user had: the frontmost app gets
/// it, whatever it is.
///
/// [LAW:effects-at-boundaries] Posting an event is an effect against the window
/// server and needs Accessibility. It sits behind this seam so the paste above it
/// runs in tests against an app the test plays.
/// [LAW:one-type-per-behavior] Cmd+V for a paste and a SendKeys action's chord are the
/// same press to the OS, so they are the same call here.
@MainActor
public protocol KeyPoster {
    func post(_ chord: KeyChord)
}

public struct SystemKeyPoster: KeyPoster {
    public init() {}

    /// The modifiers go down in a fixed order, the key goes down and up under them,
    /// and they come back up in reverse, which is what a person's hands do.
    public func post(_ chord: KeyChord) {
        // Events from a private source carry the flags set here and nothing the user's
        // hands are doing at the same moment.
        let source = CGEventSource(stateID: .privateState)
        let modifiers = Modifier.allCases.filter(chord.modifiers.contains)
        var flags: CGEventFlags = []
        for modifier in modifiers {
            flags.formUnion(modifier.eventFlags)
            Self.post(key: modifier.hardware.keyCode, down: true, flags: flags, type: .flagsChanged, source: source)
        }
        if let key = chord.key {
            Self.post(key: CGKeyCode(key.rawValue), down: true, flags: flags, type: .keyDown, source: source)
            Self.post(key: CGKeyCode(key.rawValue), down: false, flags: flags, type: .keyUp, source: source)
        }
        for modifier in modifiers.reversed() {
            flags.subtract(modifier.eventFlags)
            Self.post(key: modifier.hardware.keyCode, down: false, flags: flags, type: .flagsChanged, source: source)
        }
    }

    private static func post(key: CGKeyCode, down: Bool, flags: CGEventFlags, type: CGEventType, source: CGEventSource?) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else {
            preconditionFailure("CoreGraphics refused a keyboard event for key code \(key)")
        }
        event.type = type
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}

extension Modifier {
    /// The flags a posted event carries while this modifier is held: the side-blind
    /// mask apps match shortcuts against, and the device bit that names the side.
    var eventFlags: CGEventFlags {
        let sideBlind: CGEventFlags = switch self {
        case .leftShift, .rightShift: .maskShift
        case .leftControl, .rightControl: .maskControl
        case .leftOption, .rightOption: .maskAlternate
        case .leftCommand, .rightCommand: .maskCommand
        case .function: .maskSecondaryFn
        }
        return sideBlind.union(CGEventFlags(rawValue: hardware.mask))
    }
}
