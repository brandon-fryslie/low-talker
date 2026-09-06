import AppKit
import ApplicationServices
import ArgumentParser
import Foundation
import KeyboardLayout
import KeyboardService
import Keystrokes
import LowTalkerCore
import VirtualKeyboard

/// The spike behind low-keyboard-3ti.2: keystrokes sent to the
/// Karabiner-DriverKit-VirtualHIDDevice driver extension from this process, with as
/// little between as macOS allows, to measure the premise before a module or a helper
/// exists.
///
/// What macOS allows is less than the ticket assumed. The extension's user client
/// opens only for a process holding `com.apple.developer.driverkit.userclient-access`
/// for its bundle id, an entitlement Apple grants per app id; root without it gets
/// kIOReturnNotPermitted, measured here. The package ships the one process that holds
/// it, Karabiner-VirtualHIDDevice-Daemon, which runs as root and takes reports over a
/// Unix domain socket in a root-only directory. That socket is the way in, and root is
/// what it takes to reach it: `type` needs sudo. `watch` runs as the user and needs
/// the terminal's Input Monitoring and Accessibility, like `hotkey`.
struct DextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dext",
        abstract: "Type through the virtual keyboard driver extension, and watch what arrives.",
        subcommands: [DextTypeCommand.self, DextWatchCommand.self]
    )
}

/// Types text into a named app as the virtual keyboard and reads it back off that app's
/// focused element through Accessibility, so what it prints is measured, not assumed.
/// Naming the app is what keeps a window that steals focus from swallowing the text.
struct DextTypeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text through the driver extension into a named app (needs sudo)."
    )

    @Argument(help: "The bundle id of the app to type into, e.g. com.apple.TextEdit.")
    var into: BundleID

    @Argument(help: "The text to type. Anything the current keyboard layout has keys for, dead-key sequences included.")
    var text: String

    /// [LAW:no-mode-explosion] Which keyboard, as a value on the one typing command,
    /// rather than a second command that would be this one with four lines changed and
    /// every later fix owed to both.
    @Option(name: .customLong("through"), help: "Where the keystrokes go: the driver in this process, which needs root, or the installed helper, which does not.")
    var through: Through = .device

    @Option(name: .customLong("layout"), help: "The keyboard layout to type through, by input source id (com.apple.keylayout.Dvorak). Defaults to this process's own, which under sudo is root's US and not the console user's - so a machine on any other layout needs this said.")
    var layoutID: String?

    @MainActor
    func run() async throws {
        // Named rather than discovered when it has to be. This command runs as root, and
        // root is answered with root's own layout: on a machine switched to Dvorak, the
        // console user is told Dvorak and this process is told US. Typing US keys under
        // Dvorak types something else entirely and every check here would still pass, so
        // the layout is printed whether it was named or found. [LAW:no-silent-failure]
        let layout = try layoutID.map { try KeyboardLayout.named($0) } ?? KeyboardLayout.current()
        // Printed here, where the fact becomes known, and not alongside the focus report
        // below: a run that never raises the app throws before that line, and the layout is
        // exactly what an operator needs told when the machine is not on root's US.
        print("typing through \(layout.name)")
        // After the print and not before it, so that "the layout it used" holds for a run
        // that types nothing too. Resolving a layout cannot fail differently for an empty
        // string, so the cheap check has no claim on going first.
        // [LAW:parse-dont-validate] The text is proven typeable before the daemon is
        // touched, so a refusal leaves no half-typed line behind.
        guard !text.isEmpty else { throw ValidationError("there is nothing to type") }
        let typing = try layout.typing(text)
        // What the keys will put on screen, which is not always what was asked for: a CRLF
        // is one Return, and the app writes one line break for it. Compared against this
        // rather than the argument, so a run that typed correctly is not reported as a
        // mismatch over a character no keyboard can produce. [LAW:one-source-of-truth]
        let expected = String(typing.map(\.character))
        let clock = ContinuousClock()
        // Watched before a single report goes out, so there is no window where an
        // interrupt can end the process with a key already down.
        let interrupt = Interrupt.watched()
        let opened = try through.open(clock)
        let keyboard = opened.keyboard
        // [LAW:single-enforcer] Every key is released on every way out this process
        // controls. A character is several reports, so a throw between them - a socket
        // timeout, a focus check that fails, the operator's Ctrl-C - leaves that key
        // held, and macOS repeats a held key until something releases it. One place
        // enforces that, not each throw site.
        defer {
            do { try keyboard.releaseAll() }
            // [LAW:no-silent-failure] Nowhere to throw from a defer, so it is said out
            // loud: a key may be left held and the next thing typed will show it.
            catch { print("the keyboard was not released: \(error). A key may be left held.") }
        }
        print(opened.report)

        // A press in the device's own vocabulary: a modifier is a key like any other, held
        // around the one it modifies. So a keystroke costs one report per modifier held,
        // one for the key, and one for the release - two for a bare letter, four for the
        // em dash, which holds Shift and Option. That is the faithful count: a modifier and
        // the key it modifies do not go down in the same scan on real hardware either.
        // [LAW:no-ambient-temporal-coupling] The target is stated, not discovered, and
        // every read re-checks it, so a window that steals focus mid-run is a named
        // failure rather than text delivered somewhere nobody asked for.
        let screen = TargetApp(bundleID: into, interrupt: interrupt)
        var scribe = Scribe(keyboard: GuardedKeyboard(keyboard: keyboard, interrupt: interrupt, screen: screen))

        try interrupt.check()
        try await screen.raise(within: .seconds(5))
        let start = try screen.focus()
        let before = start.text
        // Which element, not just which app: a find bar accepts keystrokes as readily as
        // a document, and reads them back just as convincingly.
        print("typing into \(into.rawValue), focus is \(start.role)")

        // From the first report on there is text in the document that cannot be taken
        // back, so every failure from here has to say how much of it landed. The guard is
        // over the region where that is true, not over one kind of error: catching only
        // ScreenUnreadable let a daemon timeout mid-burst walk past it, and leaving the
        // first press outside the block let its own failure past as well. What throws
        // does not change what the operator needs to be told. [LAW:single-enforcer]
        let first = typing[0]
        let firstPosted = clock.now
        do {
            // One character alone, so its latency is the driver's and not the queue's.
            try scribe.press(first.character, first.keystrokes)
            let firstSeen = try await screen.wait(within: .seconds(3)) { $0.occurrences(of: String(first.character)) > before.occurrences(of: String(first.character)) }
            print("first character on screen in \(into.rawValue) after \((clock.now - firstPosted).milliseconds) ms\(firstSeen ? "" : " (NEVER SEEN)")")

            let rest = Array(typing.dropFirst())
            let restPosted = clock.now
            for character in rest {
                try scribe.press(character.character, character.keystrokes)
            }
            let acknowledged = clock.now - restPosted
            // Against a baseline, like the first character's check: an app already holding
            // this text would otherwise confirm a run that delivered nothing.
            let allSeen = try await screen.wait(within: .seconds(5)) { $0.occurrences(of: expected) > before.occurrences(of: expected) }
            let settled = clock.now - restPosted
            // The count is the one the clock actually covers: the first character was
            // posted and timed above, on its own, and is not in this window.
            // [LAW:one-source-of-truth] With nothing after that character there is no
            // burst, and no window either - "0 more in 0.0 ms, all 1 on screen after
            // 0.1 ms" is measured from after the character had already landed and reads
            // as a claim about it, which the line above has already made properly.
            if !rest.isEmpty {
                print("\(rest.count) more characters posted and acknowledged in \(acknowledged.milliseconds) ms, all \(typing.count) on screen after \(settled.milliseconds) ms")
            }
            if allSeen {
                print("the screen holds the text, complete and in order")
            } else {
                // The mismatch report is the entire output of a bad run, so it is not
                // allowed to fail on its own account. A screen that will not be read is
                // part of the report, not a reason to lose it. [LAW:no-silent-failure]
                do { print("MISMATCH: the screen holds [\(try screen.read())]") }
                catch { print("MISMATCH, and the screen would not be read afterwards: \(error)") }
            }
        } catch {
            throw TypingStopped(typed: scribe.typed, of: typing.count, halfTyped: scribe.halfTyped, cause: error)
        }
    }
}

/// Prints every keyboard event the login session carries, through the same tap the
/// app installs, with the time from the driver's stamp to the tap's callback.
struct DextWatchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Print each keyboard event the session's event tap sees until interrupted."
    )

    @MainActor
    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let (events, continuation) = AsyncStream.makeStream(of: (KeyEvent, Duration).self)
        _ = try SystemKeyboardTap().install(
            handling: { event in
                continuation.yield((event, .nanoseconds(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))))
                return .pass
            },
            onLapse: { print("the tap lapsed and was switched back on") }
        )
        print("watching the session's keyboard events")
        for await (event, arrived) in events {
            let key = switch event.key {
            case .key(let key): "key \(key.rawValue)"
            case .modifier(let modifier): "modifier \(modifier.rawValue)"
            }
            print("\(event.direction) \(key) stamp-to-tap \((arrived - event.time).microseconds) us")
        }
    }
}

extension BundleID: ExpressibleByArgument {}

/// The virtual keyboard, refusing any keystroke this run has lost the right to post.
/// [LAW:decomposition] The three things a keystroke depends on - the device, the
/// operator's interrupt, and the app in front - meet here and nowhere else, so `Scribe`
/// presses keys without knowing what a window server is.
struct GuardedKeyboard: Keyboard {
    let keyboard: any KeyPress
    let interrupt: Interrupt
    let screen: TargetApp

    func check() throws {
        try interrupt.check()
        try screen.requireFrontmost()
    }

    func down(_ usage: Usage) throws { try keyboard.down(usage) }
    func releaseAll() throws { try keyboard.releaseAll() }
}

/// A run that stopped once text was already in the target: focus moved, the daemon went
/// quiet, the operator interrupted it. What stopped it is the cause; how much is in the
/// document is the part only this knows, and the part the operator has to act on, since
/// text already typed cannot be taken back.
struct TypingStopped: Error, CustomStringConvertible {
    let typed: Int
    let of: Int
    /// The character whose first keystroke landed and whose last did not, when the run
    /// stopped inside one. It is not in the count, because it is not on screen; it is in
    /// the target app as a pending accent, which is a different thing to act on.
    var halfTyped: Character?
    let cause: any Error
    var description: String {
        // "Posted and acknowledged", not "typed", and the difference is this spike's
        // whole finding: the daemon acknowledges reports the driver then drops, so the
        // count is what left here and an upper bound on what landed, never a delivery
        // receipt. A run interrupted at 445 has been seen to leave 436 in the document.
        let progress = typed < of
            ? "\(typed) of \(of) characters had been posted and acknowledged before this, and the rest were not sent"
            : "all \(of) characters had been posted and acknowledged before this"
        // A dead key posted without the letter after it leaves the app mid-composition,
        // which no reset here can clear and which silently changes the next character
        // that app receives. [LAW:no-silent-failure]
        let pending = halfTyped.map { ", and \(String($0).debugDescription) was left half typed: its accent is pending in the app and will combine with whatever it receives next" } ?? ""
        return "\(cause). \(progress)\(pending)"
    }
}

/// Ctrl-C, as a value the run reads rather than a way out that skips the run's own
/// ending. SIGINT's default disposition ends the process where it stands, so an interrupt
/// during a burst leaves a key down with nothing left to release it, and macOS repeats
/// that key into whatever app comes forward next - the exact failure this command exists
/// to study. Ignored as a signal and watched as a source instead, it becomes something
/// the run can read and stop for, unwinding through the same release every other
/// failure takes. [LAW:dataflow-not-control-flow]
///
/// Being ignored has a price worth stating plainly: the signal no longer ends a blocking
/// read either, so it is seen only where something asks. Every loop that waits on another
/// process asks - raising the app, polling the screen, each keystroke of the burst - and
/// so does each step between them. What is left is the daemon's own reads, so an
/// interrupt arriving inside one is seen when that read returns, at most two seconds
/// later.
final class Interrupt: @unchecked Sendable {
    private let lock = NSLock()
    private var raised: Int32?
    private var sources: [any DispatchSourceSignal] = []

    static func watched(_ numbers: [Int32] = [SIGINT, SIGTERM]) -> Interrupt {
        let interrupt = Interrupt()
        interrupt.sources = numbers.map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { interrupt.raise(number) }
            return source
        }
        interrupt.sources.forEach { $0.resume() }
        return interrupt
    }

    private func raise(_ number: Int32) {
        lock.lock()
        defer { lock.unlock() }
        raised = raised ?? number
    }

    /// [LAW:no-silent-failure] An interrupt is a named failure like any other, so it
    /// travels the same path and is reported with the same count beside it.
    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if let raised { throw Interrupted(number: raised) }
    }
}

struct Interrupted: Error, CustomStringConvertible {
    let number: Int32
    var description: String { "interrupted by signal \(number)" }
}

// MARK: - Reading the screen back

/// The one app this run types into: raised so the keystrokes land there, then read
/// back through Accessibility — the document in TextEdit, the screen in Terminal.
@MainActor
struct TargetApp {
    /// The app the caller means to type into; anything else in front is a refusal.
    /// [LAW:one-type-per-behavior] BundleID already names an app target everywhere else
    /// in this codebase, so this seam speaks it rather than a second bare String.
    let bundleID: BundleID
    /// Every loop in here waits on another process, and a wait is where an interrupt
    /// arrives. Ignoring the signal to keep it away from the driver's key state means
    /// nothing observes it unless something asks, so each poll asks.
    let interrupt: Interrupt

    /// Brings the target to the front and waits for macOS to agree it is there.
    /// [LAW:no-ambient-temporal-coupling] Focus is a state this command drives and
    /// confirms, never a condition it hopes the shell arranged beforehand.
    func raise(within limit: Duration) async throws {
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
    func requireFrontmost() throws -> NSRunningApplication {
        guard let app = NSWorkspace.shared.frontmostApplication else { throw ScreenUnreadable.noFrontmostApp }
        let name = app.bundleIdentifier ?? "pid \(app.processIdentifier)"
        guard name == bundleID.rawValue else { throw ScreenUnreadable.wrongApp(wanted: bundleID.rawValue, frontmost: name) }
        return app
    }

    /// What the app's focus actually is, and what it holds. The role travels with the
    /// text because naming the app does not name the element inside it: a find bar, a
    /// search field and the document are all equally "frontmost", and a run that types
    /// into the wrong one reads its own text back and calls itself correct.
    struct Focus {
        let role: String
        let text: String
    }

    /// [LAW:no-silent-failure] A screen that cannot be read is said so, never reported
    /// as an empty one: empty is what the verdict compares against.
    func focus() throws -> Focus {
        let (element, name) = try focusedElement()
        var role: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return Focus(role: role as? String ?? "an element that will not name its role", text: try Self.text(of: element, in: name))
    }

    /// The value alone. [LAW:decomposition] `wait` polls this every 2 ms for seconds at a
    /// time, and the role it does not use is another synchronous call into the app whose
    /// main thread the poll rate was chosen to leave alone - the reading would have been
    /// loading the very thing it measures.
    func read() throws -> String {
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
        let application = AXUIElementCreateApplication(app.processIdentifier)
        // A bound this code states is a bound it has to keep. An Accessibility read is a
        // synchronous call into another process, and left at the system default one read
        // of an app whose main thread is busy can outlast the whole `within` it was made
        // under - so `wait(within: .seconds(3))` would quietly take longer than three
        // seconds. [FRAMING:representation] A stated bound the code cannot hold is a map
        // that does not match its territory. Half a second is far above the 10-35 ms an
        // answer takes here and far below any budget it is polled inside.
        AXUIElementSetMessagingTimeout(application, 0.5)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let element = Self.element(focused) else { throw ScreenUnreadable.noFocus(name) }
        AXUIElementSetMessagingTimeout(element, 0.5)
        return (element, name)
    }

    /// The answer as an element, when the app answered with one. A CoreFoundation value
    /// admits no cast check, so its type id is the check. [LAW:parse-dont-validate] This
    /// command is pointed at whatever bundle id the caller names, and an app whose
    /// Accessibility implementation answers this query with something else would
    /// otherwise trap the process where it should have been refused by name.
    /// LowTalkerCore's PasteMenuItem guards the same cast the same way; 3ti.12 takes
    /// reading the screen over from both and is where the two become one.
    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Polls the focused text until `condition` holds or `limit` passes: an app paints
    /// when it paints, so the wait is on the state and the bound is the verdict.
    func wait(within limit: Duration, until condition: (String) -> Bool) async throws -> Bool {
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
            // the number this command exists to report.
            try await Task.sleep(for: .milliseconds(2))
        }
        if let unanswered { throw unanswered }
        return false
    }
}

enum ScreenUnreadable: Error, CustomStringConvertible {
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

    /// Whether waiting could still change the answer. An app that will not answer right
    /// now may answer in two milliseconds; an app that is not in front is not going to
    /// come back on its own, and a wait that rides that out delivers a late verdict about
    /// the wrong window. [LAW:types-are-the-program] The cases already carry the
    /// difference, so nothing has to inspect a message to find it.
    var mayPassWithTime: Bool {
        switch self {
        case .noFocus, .noText: true
        case .noFrontmostApp, .notRunning, .wouldNotComeForward, .wrongApp: false
        }
    }

    var description: String {
        switch self {
        case .noFrontmostApp: "no app is frontmost, so there is no focused element to read"
        case .notRunning(let app): "\(app) is not running, so there is nothing to type into"
        case .wouldNotComeForward(let wanted, let frontmost): "\(wanted) would not come to the front, \(frontmost) is there; nothing was typed"
        case .wrongApp(let wanted, let frontmost): "\(frontmost) is frontmost, not \(wanted)"
        case .noFocus(let app): "\(app) has no focused element; is this process allowed under Accessibility?"
        case .noText(let app): "the focused element in \(app) carries no text value"
        }
    }
}

extension String {
    /// [LAW:one-type-per-behavior] One counter serves both checks; the first character's
    /// is this with a one-character needle.
    func occurrences(of text: String) -> Int {
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

extension Duration {
    /// Milliseconds to a tenth, the resolution a keystroke's latency needs.
    var milliseconds: String {
        fixed(Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15, places: 1)
    }

    var microseconds: Int64 {
        components.seconds * 1_000_000 + components.attoseconds / 1_000_000_000_000
    }
}
