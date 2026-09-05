import AppKit
import ApplicationServices

/// An app asked to paste. The real receiver presses the app's own Paste menu item; a
/// test's reads the pasteboard the way a text field would.
///
/// [LAW:effects-at-boundaries] The press is an Accessibility call into another
/// process. Behind this seam the inserter runs in tests against an app the test plays.
@MainActor
public protocol PasteReceiver: Sendable {
    /// Returns once the app has run its paste, so the pasteboard may change after it.
    func paste() async throws
}

/// Why an app could not be asked to paste, or did not say that it had.
public enum PasteError: Error, Hashable, CustomStringConvertible {
    /// No menu item is bound to plain Cmd+V, so the app has no paste to press.
    case noPasteMenuItem(bundleID: String?)
    /// The app validated its Paste item as disabled after the text was on the
    /// pasteboard, and a press would do nothing.
    case pasteDisabled(bundleID: String?)
    /// Accessibility refused before the press: this process is not trusted, or the app
    /// did not answer.
    case accessibility(AXError)
    /// The app took the press but did not answer afterward, so whether it pasted is
    /// unknown; the press cannot be taken back.
    case unanswered(AXError)

    public var description: String {
        switch self {
        case .noPasteMenuItem(let bundleID):
            "\(bundleID ?? "the frontmost app") has no menu item bound to Cmd+V, so it cannot be asked to paste"
        case .pasteDisabled(let bundleID):
            "\(bundleID ?? "the frontmost app") has its Paste menu item disabled, so pressing it would do nothing"
        case .accessibility(.apiDisabled):
            "Accessibility is off for the calling process; grant it in System Settings > Privacy & Security > Accessibility"
        case .accessibility(let error):
            "Accessibility call failed (AXError \(error.rawValue)) before the paste was pressed"
        case .unanswered(let error):
            "the app took the paste but did not answer afterward (AXError \(error.rawValue)); it may or may not have pasted"
        }
    }
}

/// An app's Paste menu item, pressed through Accessibility.
///
/// Pressing the item is what Cmd+V means to the app, without the key event. A posted
/// chord says nothing about when the app acts on it, and a clipboard manager pulling
/// the pasteboard is indistinguishable from the paste. The press is a message the app
/// handles in order with every other Accessibility message, so whatever it answers
/// next, it answers after the paste has run.
///
/// [LAW:parse-dont-validate] Making one is the check that the app has a paste to
/// press; holding one is the proof. Whether the app will act on a press is its own
/// word at press time.
@MainActor
public struct PasteMenuItem: PasteReceiver {
    private let app: AXUIElement
    private let item: AXUIElement
    private let bundleID: String?

    /// Finds the item bound to plain Cmd+V in the app's menu bar, breadth first, so the
    /// Edit menu's item is found before any submenu is walked.
    public init(of app: NSRunningApplication) throws {
        bundleID = app.bundleIdentifier
        self.app = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar = element(try read(self.app, kAXMenuBarAttribute)),
              let found = try breadthFirst(from: children(of: bar), children: children(of:), where: isBoundToPlainCmdV)
        else { throw PasteError.noPasteMenuItem(bundleID: bundleID) }
        item = found
    }

    /// AppKit validates an app's menu bar on a clock of its own, once a second
    /// (measured on macOS 26 at 1.0 s, active or not). A reading taken within a period
    /// of a change may predate it.
    public static let menuValidationPeriod: Duration = .seconds(1)

    /// Whether a menu item's key equivalent, as Accessibility reports it, is plain
    /// Cmd+V: the character is the capital V Accessibility reports whatever case the
    /// app set, and an empty modifier mask means Cmd alone.
    nonisolated public static func isPlainCmdV(cmdChar: String?, modifiers: Int?) -> Bool {
        cmdChar == "V" && modifiers == 0
    }

    /// [LAW:no-ambient-temporal-coupling] Two clocks own the waits here, and both are
    /// named. Accessibility bounds each call by its messaging timeout (1.5 s by
    /// default), so an app that has hung costs that much and then fails the call.
    /// AppKit's validation pass bounds the other: a disabled reading is trusted only
    /// once a full period has passed without it changing.
    public func paste() async throws {
        // A press keeps to the app's last validation: pressing an item validated
        // disabled returns success and does nothing. The text went on the pasteboard
        // just now, so a disabled reading may be older than it; the next pass settles
        // that. [LAW:single-enforcer] Only the app says whether its paste can run; an
        // app that does not say is pressed.
        let enabled = try await holds(within: Self.menuValidationPeriod, askingEvery: .milliseconds(50)) {
            try read(item, kAXEnabledAttribute) as? Bool != false
        }
        guard enabled else { throw PasteError.pasteDisabled(bundleID: bundleID) }
        let sent = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard sent == .success else { throw PasteError.accessibility(sent) }
        // The press returns once sent, not once run; this answer comes after the run.
        var role: CFTypeRef?
        let answered = AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &role)
        guard answered == .success else { throw PasteError.unanswered(answered) }
    }
}

private func isBoundToPlainCmdV(_ element: AXUIElement) throws -> Bool {
    try PasteMenuItem.isPlainCmdV(
        cmdChar: read(element, kAXMenuItemCmdCharAttribute) as? String,
        modifiers: read(element, kAXMenuItemCmdModifiersAttribute) as? Int
    )
}

/// An attribute's value: nil when the element has none, thrown when Accessibility
/// itself fails.
private func read(_ element: AXUIElement, _ attribute: String) throws -> CFTypeRef? {
    var value: CFTypeRef?
    switch AXUIElementCopyAttributeValue(element, attribute as CFString, &value) {
    case .success: return value
    case .noValue, .attributeUnsupported: return nil
    case let failure: throw PasteError.accessibility(failure)
    }
}

private func children(of element: AXUIElement) throws -> [AXUIElement] {
    try read(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

/// The value as an element, when the app answered with one. A CoreFoundation value
/// admits no cast check, so its type id is the check.
private func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}
