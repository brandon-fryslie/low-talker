import AppKit
import ApplicationServices
import LowTalkerCore

/// The one app a run types into: raised so the keystrokes land there, re-proven in front
/// before every key, and read back through Accessibility - the document in TextEdit, the
/// screen in Terminal.
@MainActor
public struct TargetApp {
    /// The app the caller means to type into; anything else in front is a refusal.
    /// [LAW:one-type-per-behavior] BundleID already names an app target everywhere else
    /// in this codebase, so this seam speaks it rather than a second bare String.
    public let bundleID: BundleID
    /// Every loop in here waits on another process, and a wait is where an interrupt
    /// arrives. Ignoring the signal to keep it away from the driver's key state means
    /// nothing observes it unless something asks, so each poll asks.
    public let interrupt: Interrupt

    public init(bundleID: BundleID, interrupt: Interrupt) {
        self.bundleID = bundleID
        self.interrupt = interrupt
    }

    /// Brings the target to the front and waits for macOS to agree it is there.
    /// [LAW:no-ambient-temporal-coupling] Focus is a state this drives and confirms,
    /// never a condition it hopes the shell arranged beforehand.
    public func raise(within limit: Duration) async throws {
        guard let target = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID.rawValue }) else {
            throw ScreenUnreadable.notRunning(bundleID.rawValue)
        }
        let clock = ContinuousClock()
        let start = clock.now
        repeat {
            try interrupt.check()
            target.activate()
            try await Task.sleep(for: .milliseconds(100))
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID.rawValue { return }
        } while clock.now - start < limit
        throw ScreenUnreadable.wouldNotComeForward(wanted: bundleID.rawValue, frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nothing")
    }

    /// [LAW:parse-dont-validate] The one place focus is decided. It returns the target
    /// app only when the target is the app in front, so a caller holding the result holds
    /// the proof and nothing downstream asks again. [LAW:single-enforcer]
    @discardableResult
    public func requireFrontmost() throws -> NSRunningApplication {
        guard let app = NSWorkspace.shared.frontmostApplication else { throw ScreenUnreadable.noFrontmostApp }
        let name = app.bundleIdentifier ?? "pid \(app.processIdentifier)"
        guard name == bundleID.rawValue else { throw ScreenUnreadable.wrongApp(wanted: bundleID.rawValue, frontmost: name) }
        return app
    }

    /// What the app's focus actually is, and what it holds. The role travels with the
    /// text because naming the app does not name the element inside it: a find bar, a
    /// search field and the document are all equally "frontmost", and a run that types
    /// into the wrong one reads its own text back and calls itself correct.
    public struct Focus {
        public let role: String
        public let text: String
    }

    /// [LAW:no-silent-failure] A screen that cannot be read is said so, never reported
    /// as an empty one: empty is what the verdict compares against.
    public func focus() throws -> Focus {
        let (element, name) = try focusedElement()
        var role: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return Focus(role: role as? String ?? "an element that will not name its role", text: try Self.text(of: element, in: name))
    }

    /// The value alone. [LAW:decomposition] `wait` polls this every 2 ms for seconds at a
    /// time, and the role it does not use is another synchronous call into the app whose
    /// main thread the poll rate was chosen to leave alone - the reading would have been
    /// loading the very thing it measures.
    public func read() throws -> String {
        let (element, name) = try focusedElement()
        return try Self.text(of: element, in: name)
    }

    private static func text(of element: AXUIElement, in name: String) throws -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success, let text = value as? String else { throw ScreenUnreadable.noText(name) }
        return text
    }

    /// The focused element, with the app re-proven frontmost first. Both readings come
    /// through here, so neither can quietly read an app the caller did not name.
    private func focusedElement() throws -> (AXUIElement, String) {
        let app = try requireFrontmost()
        let name = bundleID.rawValue
        let application = Self.application(of: app)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let element = Self.element(focused) else { throw ScreenUnreadable.noFocus(name) }
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        return (element, name)
    }

    /// A bound this code states is a bound it has to keep. An Accessibility read is a
    /// synchronous call into another process, and left at the system default one read of
    /// an app whose main thread is busy can outlast the whole `within` it was made under -
    /// so `wait(within: .seconds(3))` would quietly take longer than three seconds.
    /// [FRAMING:representation] A stated bound the code cannot hold is a map that does not
    /// match its territory. Half a second is far above the 10-35 ms an answer takes here
    /// and far below any budget it is polled inside. Set on every element this reads,
    /// because the timeout is per element and a child does not inherit its parent's.
    private static let messagingTimeout: Float = 0.5

    private static func application(of app: NSRunningApplication) -> AXUIElement {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        return application
    }

    /// The most elements one search reads out of the app. A tree is read one synchronous
    /// call per element and a browser's is tens of thousands wide, so a search that walked
    /// all of it would outlast any budget it was made under; it stops here and says so. A
    /// dialog, which is what this is for, is a few dozen.
    public static let searchLimit = 2000
    /// The most time one search is given. The element cap bounds the reads and the
    /// messaging timeout bounds each one, and an app that answers slowly stays under both
    /// for minutes; this is the bound a caller is actually promised.
    public static let searchBudget: Duration = .seconds(5)

    /// The screen frame of the first element, breadth first from the app, with this role
    /// and title: global coordinates, top-left origin, points - the space the cursor is
    /// read back in, so the centre of the frame is a click's target with no conversion.
    /// The app is re-proven in front first, so the element is in the app the caller named
    /// and not in whatever took the front.
    public func frame(ofRole role: AccessibilityRole, titled title: String) throws -> CGRect {
        let app = try requireFrontmost()
        let name = bundleID.rawValue
        let clock = ContinuousClock()
        let start = clock.now
        var read = 0
        let found = try breadthFirst(from: [Self.application(of: app)], children: { element in
            try interrupt.check()
            read += 1
            guard read <= Self.searchLimit else { throw ScreenUnreadable.tooManyElements(name, limit: Self.searchLimit) }
            guard clock.now - start < Self.searchBudget else { throw ScreenUnreadable.searchTooSlow(name, within: Self.searchBudget) }
            return Self.children(of: element)
        }, where: { Self.string(kAXRoleAttribute, of: $0) == role.rawValue && Self.string(kAXTitleAttribute, of: $0) == title })
        guard let found else { throw ScreenUnreadable.noElement(role: role.rawValue, title: title, app: name) }
        guard let origin = Self.value(kAXPositionAttribute, of: found, as: .cgPoint, CGPoint.zero),
              let size = Self.value(kAXSizeAttribute, of: found, as: .cgSize, CGSize.zero) else {
            throw ScreenUnreadable.elementWithoutFrame(role: role.rawValue, title: title, app: name)
        }
        return CGRect(origin: origin, size: size)
    }

    /// The element's children, each bounded like everything else read here. An element
    /// that answers with no children is a leaf, which is what a leaf is.
    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        let children = (value as? [CFTypeRef] ?? []).compactMap(Self.element)
        children.forEach { AXUIElementSetMessagingTimeout($0, messagingTimeout) }
        return children
    }

    private static func string(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value as? String
    }

    /// A geometry attribute unboxed from its `AXValue`, when the app answered with one of
    /// the type asked for. The type id is the check, for the reason `element` gives.
    private static func value<T>(_ attribute: String, of element: AXUIElement, as type: AXValueType, _ empty: T) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var unboxed = empty
        guard AXValueGetValue(value as! AXValue, type, &unboxed) else { return nil }
        return unboxed
    }

    /// The answer as an element, when the app answered with one. A CoreFoundation value
    /// admits no cast check, so its type id is the check. [LAW:parse-dont-validate] This
    /// is pointed at whatever bundle id the caller names, and an app whose Accessibility
    /// implementation answers this query with something else would otherwise trap the
    /// process where it should have been refused by name. LowTalkerCore's PasteMenuItem
    /// guards the same cast the same way; 3ti.12 takes reading the screen over from both
    /// and is where the two become one.
    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Polls the focused text until `condition` holds or `limit` passes: an app paints
    /// when it paints, so the wait is on the state and the bound is the verdict.
    public func wait(within limit: Duration, until condition: (String) -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        var unanswered: ScreenUnreadable?
        // The deadline is checked after the read, not before it, so the last read lands on
        // the tick past the limit and the app gets that tick - and so the screen is read in
        // one place. A second read outside the loop is a second place to remember the catch
        // below, and the poll that happens to see the popup decides whether the wait fails.
        while true {
            try interrupt.check()
            do {
                if condition(try read()) { return true }
                unanswered = nil
            } catch let unreadable as ScreenUnreadable where unreadable.mayPassWithTime {
                // A poll that did not get an answer is not the end of the wait; riding
                // out a moment like this is what polling is for. TextEdit's own
                // autocorrect popup takes the focused element away for a few frames, and
                // ending a five-second wait on it reports a failure about a run that
                // typed all 500 characters correctly. The bound is still the verdict:
                // something that lasts to the deadline is raised there, by name.
                unanswered = unreadable
            }
            guard clock.now - start < limit else { break }
            // Far below the 10-35 ms being measured, and far above a rate that would load
            // the target app's main thread with synchronous Accessibility calls and skew
            // the number this exists to report.
            try await Task.sleep(for: .milliseconds(2))
        }
        if let unanswered { throw unanswered }
        return false
    }
}

public enum ScreenUnreadable: Error, CustomStringConvertible {
    case noFrontmostApp
    case notRunning(String)
    /// Raising the target failed, which happens before a single report is posted. This
    /// is the only case that can promise nothing was typed, so it is the only one that
    /// says so. [LAW:types-are-the-program]
    case wouldNotComeForward(wanted: String, frontmost: String)
    /// The wrong app is in front. That is all this says, because it is thrown from the
    /// checks before typing and from the checks between keystrokes alike, and only the
    /// caller knows which. A single case claiming "nothing was typed" would be a lie
    /// half the time it fired.
    case wrongApp(wanted: String, frontmost: String)
    case noFocus(String)
    case noText(String)
    /// No element with that role and title, among the ones read.
    case noElement(role: String, title: String, app: String)
    case elementWithoutFrame(role: String, title: String, app: String)
    case tooManyElements(String, limit: Int)
    case searchTooSlow(String, within: Duration)

    /// Whether waiting could still change the answer. An app that will not answer right
    /// now may answer in two milliseconds; an app that is not in front is not going to
    /// come back on its own, and a wait that rides that out delivers a late verdict about
    /// the wrong window. [LAW:types-are-the-program] The cases already carry the
    /// difference, so nothing has to inspect a message to find it.
    public var mayPassWithTime: Bool {
        switch self {
        case .noFocus, .noText, .noElement: true
        case .noFrontmostApp, .notRunning, .wouldNotComeForward, .wrongApp, .elementWithoutFrame, .tooManyElements, .searchTooSlow: false
        }
    }

    public var description: String {
        switch self {
        case .noFrontmostApp: "no app is frontmost, so there is no focused element to read"
        case .notRunning(let app): "\(app) is not running, so there is nothing to type into"
        case .wouldNotComeForward(let wanted, let frontmost): "\(wanted) would not come to the front, \(frontmost) is there; nothing was typed"
        case .wrongApp(let wanted, let frontmost): "\(frontmost) is frontmost, not \(wanted)"
        case .noFocus(let app): "\(app) has no focused element; is this process allowed under Accessibility?"
        case .noText(let app): "the focused element in \(app) carries no text value"
        case .noElement(let role, let title, let app): "\(app) has no \(role) titled \(title.debugDescription); is this process allowed under Accessibility?"
        case .elementWithoutFrame(let role, let title, let app): "the \(role) titled \(title.debugDescription) in \(app) has no position or size"
        case .tooManyElements(let app, let limit): "\(app) exposes more than \(limit) elements, which is more than one search reads"
        case .searchTooSlow(let app, let limit): "\(app) did not answer an element search within \(limit)"
        }
    }
}

extension String {
    /// How many times `text` occurs, for a readback compared against a baseline: an app
    /// already holding the text would otherwise confirm a run that delivered nothing.
    /// [LAW:one-type-per-behavior] One counter serves the first character's check and the
    /// whole text's; the first is this with a one-character needle.
    public func occurrences(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = 0
        var searched = startIndex
        while let found = self[searched...].range(of: text) {
            count += 1
            searched = found.upperBound
        }
        return count
    }
}
