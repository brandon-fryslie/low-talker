import AppKit

/// The menu-bar agent. `LSUIElement` keeps it out of the Dock, so the status item
/// is the app's only surface; the delegate exists to install it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // [LAW:no-ambient-temporal-coupling] NSStatusBar is only usable once the
    // application object exists, which is after this delegate is allocated. Lazy
    // creation ties the item's lifetime to first use instead of to an optional that
    // every later reader would have to unwrap.
    private lazy var statusItem: NSStatusItem = {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "low-talker")
        item.menu = Self.makeMenu()
        return item
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.isVisible = true
    }

    private static func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit low-talker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }
}
