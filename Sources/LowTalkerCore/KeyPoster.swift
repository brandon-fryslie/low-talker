import CoreGraphics

/// Presses a chord in the login session as if the user had: the frontmost app gets
/// it, whatever it is.
///
/// [LAW:effects-at-boundaries] Posting an event is an effect against the window
/// server and needs Accessibility. It sits behind this seam so a SendKeys action runs
/// in tests against an app the test plays.
@MainActor
public protocol KeyPoster {
    func post(_ chord: KeyChord)
}

public struct SystemKeyPoster: KeyPoster {
    public init() {}

    public func post(_ chord: KeyChord) {
        // Events from a private source carry the flags set here and nothing the user's
        // hands are doing at the same moment.
        let source = CGEventSource(stateID: .privateState)
        for keystroke in chord.keystrokes {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keystroke.key, keyDown: keystroke.type == .keyDown) else {
                preconditionFailure("CoreGraphics refused a keyboard event for key code \(keystroke.key)")
            }
            event.type = keystroke.type
            event.flags = keystroke.flags
            event.post(tap: .cghidEventTap)
        }
    }
}

/// One event of a chord press, as the window server will see it.
public struct Keystroke: Equatable, Sendable {
    public let key: CGKeyCode
    public let type: CGEventType
    /// The modifiers held as this event happens, this key included when it is a
    /// modifier going down and excluded when it is one coming up.
    public let flags: CGEventFlags
}

extension KeyChord {
    /// The events of pressing this chord: the modifiers go down in a fixed order, the
    /// key goes down and up under them, and they come back up in reverse, which is what
    /// a person's hands do. Each event's flags are those of the modifiers held at that
    /// moment, so a side-blind bit stays set while either side is down.
    public var keystrokes: [Keystroke] {
        let held = Modifier.allCases.filter(modifiers.contains)
        let pressing = held.indices.map { i in
            Keystroke(key: held[i].hardware.keyCode, type: .flagsChanged, flags: Modifier.flags(of: held[...i]))
        }
        let all = Modifier.flags(of: held[...])
        let striking = key.map { [Keystroke(key: CGKeyCode($0.rawValue), type: .keyDown, flags: all), Keystroke(key: CGKeyCode($0.rawValue), type: .keyUp, flags: all)] } ?? []
        let releasing = held.indices.reversed().map { i in
            Keystroke(key: held[i].hardware.keyCode, type: .flagsChanged, flags: Modifier.flags(of: held[..<i]))
        }
        return pressing + striking + releasing
    }
}

extension Modifier {
    /// The flags an event carries while exactly these modifiers are held: each one's
    /// side-blind mask, which apps match shortcuts against, and its device bit, which
    /// names the side.
    static func flags(of held: ArraySlice<Modifier>) -> CGEventFlags {
        held.reduce(into: CGEventFlags()) { flags, modifier in
            flags.formUnion(modifier.sideBlindMask)
            flags.formUnion(CGEventFlags(rawValue: modifier.hardware.mask))
        }
    }

    private var sideBlindMask: CGEventFlags {
        switch self {
        case .leftShift, .rightShift: .maskShift
        case .leftControl, .rightControl: .maskControl
        case .leftOption, .rightOption: .maskAlternate
        case .leftCommand, .rightCommand: .maskCommand
        case .function: .maskSecondaryFn
        }
    }
}
