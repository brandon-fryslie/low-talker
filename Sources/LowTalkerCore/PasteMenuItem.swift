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
    func paste() throws
}

/// Why an app could not be asked to paste.
public enum PasteError: Error, Hashable, CustomStringConvertible {
    /// No menu item is bound to plain Cmd+V, so the app has no paste to press.
    case noPasteMenuItem(bundleID: String?)
    /// Accessibility refused: this process is not trusted, or the app did not answer.
    case accessibility(AXError)

    public var description: String {
        switch self {
        case .noPasteMenuItem(let bundleID):
            "\(bundleID ?? "the frontmost app") has no menu item bound to Cmd+V, so it cannot be asked to paste"
        case .accessibility(let error):
            "Accessibility call failed (AXError \(error.rawValue)); the calling process needs Accessibility in System Settings > Privacy & Security"
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
/// [LAW:parse-dont-validate] Making one is the check that the app can paste; holding
/// one is the proof.
@MainActor
public struct PasteMenuItem: PasteReceiver {
    private let app: AXUIElement
    private let item: AXUIElement

    /// Finds the item bound to plain Cmd+V in the app's menu bar, breadth first, so the
    /// Edit menu's item is found before any submenu is walked.
    public init(of app: NSRunningApplication) throws {
        self.app = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar = try read(self.app, kAXMenuBarAttribute) else {
            throw PasteError.noPasteMenuItem(bundleID: app.bundleIdentifier)
        }
        var queue = try children(of: bar as! AXUIElement)
        var next = queue.startIndex
        while next < queue.endIndex {
            let element = queue[next]
            next += 1
            if try read(element, kAXMenuItemCmdCharAttribute) as? String == "V",
               try read(element, kAXMenuItemCmdModifiersAttribute) as? Int == 0 {
                item = element
                return
            }
            queue += try children(of: element)
        }
        throw PasteError.noPasteMenuItem(bundleID: app.bundleIdentifier)
    }

    public func paste() throws {
        let sent = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard sent == .success else { throw PasteError.accessibility(sent) }
        // The press returns once sent, not once run; this answer comes after the run.
        _ = try read(app, kAXRoleAttribute)
    }
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
