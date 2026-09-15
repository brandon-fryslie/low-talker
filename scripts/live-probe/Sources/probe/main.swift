// What the live checks need and the CLI does not offer: the focused element's text and a
// wait for it, a wait for an app to be frontmost with a focus, a window's close, the lock
// state, a pasteboard snapshot. One probe for both checks, so a fix to how one reads the
// screen is a fix to the other. [LAW:one-source-of-truth]
import AppKit
import ApplicationServices
import CryptoKit
import LowTalkerCore

// Asked of the frontmost app, not the system-wide element: a shell outside the GUI
// session (a launchd Background domain) can reach an app's Accessibility server but
// not the system-wide one.
func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(of element: AXUIElement) -> [AXUIElement] {
    attr(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

/// Closes every `bundleID` window whose title holds `marker` through the window's own
/// close button, pressing the default button of the sheet an app raises first: Terminal
/// asks before ending the window's process, and its default answer ends it. A chord
/// would need the app frontmost, and would leave the sheet. With no such window, or
/// the app not running, there is nothing to close: the exit trap calls this on every
/// path out of the check.
@MainActor func closeWindows(of bundleID: String, titled marker: String, within seconds: Double) {
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
        let windows = { attr(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? [] }
        for window in windows().filter({ (attr($0, kAXTitleAttribute) as? String ?? "").contains(marker) }) {
            guard let close = attr(window, kAXCloseButtonAttribute) else { fail("the \(bundleID) window [\(marker)] has no close button") }
            _ = AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString)
            let gone = { !windows().contains { CFEqual($0, window) } }
            let sheet = { children(of: window).first { attr($0, kAXRoleAttribute) as? String == kAXSheetRole as String } }
            _ = waitUntil(seconds) { gone() || sheet() != nil }
            // [LAW:dataflow-not-control-flow] exception: whether the app asks is its setting, read off the sheet it raised.
            if let sheet = sheet() {
                guard let button = attr(sheet, kAXDefaultButtonAttribute) else { fail("the \(bundleID) close sheet has no default button") }
                _ = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            }
            guard waitUntil(seconds, gone) else { fail("the \(bundleID) window [\(marker)] did not close") }
        }
    }
}

@MainActor func focusedElement() -> AXUIElement? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute as CFString, &focused) == .success, let element = focused else { return nil }
    return (element as! AXUIElement)
}

@MainActor func focusedValue() -> String {
    guard let element = focusedElement() else { return "<no focused element>" }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return "<no value>" }
    return String(describing: value!)
}

/// Polls `condition` until it holds or `seconds` pass; the pty echo and an app's
/// launch are asynchronous by nature, so the check waits on their state, not a sleep.
@MainActor func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    return condition()
}

// One line per item: each type it carries with a digest of the bytes behind it.
@MainActor func pasteboardSnapshot() -> String {
    PasteboardContents(reading: .general).items.map { item in
        item.map { "\($0.type.rawValue)=\(SHA256.hash(data: $0.data).map { String(format: "%02x", $0) }.joined())" }.joined(separator: " ")
    }.joined(separator: "\n")
}

/// A wait that ran out: said on stderr, so a caller capturing stdout keeps its value.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
MainActor.assumeIsolated {
    switch args[0] {
    case "axwait":
        guard waitUntil(Double(args[2])!, { focusedValue().contains(args[1]) }) else {
            let element = focusedElement()
            let role = element.flatMap { attr($0, kAXRoleAttribute) as? String } ?? "<none>"
            let window = element.flatMap { attr($0, kAXWindowAttribute) }.flatMap { attr($0 as! AXUIElement, kAXTitleAttribute) as? String } ?? "<none>"
            fail("focused text never held [\(args[1])]; focused \(role) in window [\(window)] of \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "<none>"); last: [\(focusedValue())]")
        }
    case "ready":
        guard waitUntil(Double(args[2])!, { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == args[1] && focusedElement() != nil }) else { fail("\(args[1]) never came forward with a focus; frontmost: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "<none>")") }
    case "close": closeWindows(of: args[1], titled: args[2], within: Double(args[3])!)
    case "quit":
        // A quit request, not a chord: nothing to land in the wrong app, no prompt with no window open.
        NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).forEach { _ = $0.terminate() }
    case "front":
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { fail("no app is frontmost") }
        print(id)
    case "locked":
        // The session carries the key only while the screen is locked; no session at all
        // is a shell with no window server, which cannot tell.
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { fail("no login session: the lock state is unknown") }
        print(session["CGSSessionScreenIsLocked"] as? Bool == true ? "locked" : "unlocked")
    case "pasteboard": print(pasteboardSnapshot())
    default: exit(2)
    }
}
