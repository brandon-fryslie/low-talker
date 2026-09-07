import Foundation

/// The closed set of things low-talker can do. A route produces these; an executor at
/// the app's edge performs them.
///
/// [LAW:effects-at-boundaries] An Action is a description, not a call. The router and
/// every route stay pure and testable, and a Pipe program can hand actions back as
/// JSON because they are only data.
///
/// Every payload is labeled so the synthesized Codable form is the readable wire
/// contract Pipe programs write, e.g. `{"activateApp":{"bundleID":"com.apple.Safari"}}`.
public enum Action: Hashable, Codable, Sendable {
    case insertText(text: String, target: InsertTarget)
    case sendKeys(chord: KeyChord)
    case activateApp(bundleID: BundleID)
    case openURL(url: URL)
    /// A Shortcuts.app shortcut by name, optionally handed input text.
    case runShortcut(name: String, input: String?)
    /// Hands the transcript to an external program and reads a list of actions back as
    /// JSON. Run as argv, never through a shell.
    case pipe(executable: String, arguments: [String])
    /// Moves the pointer to a point on the screen and clicks there, `times` times.
    case click(at: ScreenPoint, button: MouseButton, times: Clicks)
    /// Moves the pointer to a point and rolls the wheel there, in wheel counts: vertical
    /// positive away from the hand, horizontal positive to the right.
    case scroll(at: ScreenPoint, vertical: WheelCounts, horizontal: WheelCounts)
    /// Clicks the centre of the first Accessibility element in the frontmost app with
    /// this role and title, wherever it is on the screen.
    case clickElement(role: AccessibilityRole, title: String)
}

/// A point on the screen in global coordinates: points, origin at the top left of the
/// main display, y growing downward. The space Accessibility reports frames in and the
/// space the cursor is read back in, so a frame's centre is a click's target with no
/// conversion between.
public struct ScreenPoint: Hashable, Codable, Sendable, CustomStringConvertible {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var description: String { String(format: "(%g, %g)", x, y) }
}

/// The three buttons a click names. The device has 32; the ones a route can ask for are
/// the ones a person has a name for.
public enum MouseButton: String, Hashable, Codable, Sendable {
    case left, right, middle
}

/// How many times a click clicks: one, two or three, the counts macOS gives a meaning.
/// Zero is not a click and a fourth click means nothing more than a third, so both are
/// refused where the number is made, and a decoded one is refused there too - the same
/// way a confidence outside 0...1 is. [LAW:parse-dont-validate]
public struct Clicks: RawRepresentable, Hashable, Codable, Sendable {
    public static let limit = 3
    public let rawValue: Int

    public init?(rawValue: Int) {
        guard (1...Self.limit).contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public static let single = Clicks(rawValue: 1)!
    public static let double = Clicks(rawValue: 2)!
}

/// How far a scroll rolls the wheel on one axis, in the wheel's own counts, within a
/// bound no gesture crosses: a thousand counts is eight full reports. The bound is here,
/// where the number is made and decoded, so a Pipe program handing back a huge value is
/// refused before a report goes out rather than posting reports until it is killed.
/// [LAW:parse-dont-validate]
public struct WheelCounts: RawRepresentable, Hashable, Codable, Sendable {
    public static let limit = 1000
    public let rawValue: Int

    public init?(rawValue: Int) {
        guard abs(rawValue) <= Self.limit else { return nil }
        self.rawValue = rawValue
    }

    public static let none = WheelCounts(rawValue: 0)!
}

/// Where inserted text goes: the focused element, or a named app regardless of focus.
public enum InsertTarget: Hashable, Codable, Sendable {
    case focus
    case app(bundleID: BundleID)
}
