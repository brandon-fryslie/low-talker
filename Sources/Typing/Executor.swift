import Foundation
import KeyboardLayout
import LowTalkerCore
import os

/// Performs a route's actions on the devices: text typed into the app it names, chords
/// pressed in the app in front, clicks and scrolls made in the app in front.
///
/// [LAW:effects-at-boundaries] The router hands back descriptions; this is the edge
/// where they become reports. The keyboard and the pointer are values it is given per
/// target - the helper behind a focus check in the app, a refusing fake in a test - so
/// the executor itself decides only which app each action means and how much of it was
/// done.
///
/// Every action is lowered before any is performed. An action list is a whole the same
/// way a string is: a list that typed its first action and refused its second would
/// leave half a route in the document, and the half is not marked as half.
/// [LAW:parse-dont-validate]
@MainActor
public struct Executor {
    /// The keyboard for one target app: pressed through the helper, and refusing every
    /// key once that app is no longer in front.
    public typealias Keyboards = @MainActor (BundleID) -> any Keyboard
    /// The pointer for one target app, refusing every report the same way.
    public typealias Pointers = @MainActor (BundleID) -> Pointer

    private let keyboard: Keyboards
    private let mouse: Pointers
    private let hotkeys: Set<KeyChord>
    private let log: Logger

    /// `hotkeys` are the chords the tap listens for, which no action may press.
    public init(keyboard: @escaping Keyboards, mouse: @escaping Pointers, hotkeys: Set<KeyChord>, log: Logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "lowtalker", category: "typist")) {
        self.keyboard = keyboard
        self.mouse = mouse
        self.hotkeys = hotkeys
        self.log = log
    }

    /// One action, done. The time is from the hotkey's key-up to the helper's
    /// acknowledgement of the last report, which is the number the app has to keep
    /// under its latency target and not a claim that the text is on screen: the daemon
    /// acknowledges reports the driver then drops, and reading the screen back is the
    /// CLI's measurement.
    public struct Performed: CustomStringConvertible, Sendable {
        public enum What: Sendable {
            case typed(characters: Int)
            case pressed(KeyChord)
            /// `reports` is how many motion reports the cursor took to get there, which
            /// is the acceleration loop's cost and the number worth reading off a run.
            case clicked(at: ScreenPoint, button: MouseButton, times: Clicks, reports: Int)
            case scrolled(at: ScreenPoint, vertical: WheelCounts, horizontal: WheelCounts)
        }

        public let what: What
        public let into: BundleID
        public let acknowledged: Duration

        public var description: String {
            let act = switch what {
            case .typed(let characters): "typed \(characters) characters"
            case .pressed(let chord): "pressed \(chord.spelled)"
            case .clicked(let at, let button, let times, let reports): "clicked \(button.rawValue) \(times.spelled) at \(at) after \(reports) move reports"
            case .scrolled(let at, let vertical, let horizontal): "scrolled vertical \(vertical.rawValue) horizontal \(horizontal.rawValue) at \(at)"
            }
            return "\(act) into \(into.rawValue), key-up to acknowledged \(Int(acknowledged / .milliseconds(1))) ms"
        }
    }

    /// Performs every action in order, each logged as it completes, and answers with
    /// what was done. Throws before the first report when any action is one the devices
    /// cannot perform, cannot be typed on the layout, or would press the hotkey; throws
    /// `RouteStopped` from the action that stopped, carrying the earlier ones, which are
    /// done.
    @discardableResult
    public func perform(_ actions: [Action], in context: Context, on layout: KeyboardLayout, since keyUp: ContinuousClock.Instant) throws -> [Performed] {
        let lowered = try actions.map { try lower($0, in: context, on: layout) }
        let clock = ContinuousClock()
        var performed: [Performed] = []
        for step in lowered {
            let what: Performed.What
            do { what = try step.perform() } catch { throw RouteStopped(performed: performed, cause: error) }
            let done = Performed(what: what, into: step.into, acknowledged: clock.now - keyUp)
            log.info("\(done.description, privacy: .public)")
            performed.append(done)
        }
        return performed
    }

    /// An action as reports on the device for its target, proven before any is posted.
    private struct Step {
        let into: BundleID
        let perform: () throws -> Performed.What
    }

    private func lower(_ action: Action, in context: Context, on layout: KeyboardLayout) throws -> Step {
        switch action {
        case .insertText(let text, let target):
            // The focus is whatever app was in front when the hotkey went down, which
            // the context already names; typing into it re-proves it in front before
            // every key. A named app is typed into the same way, without being raised:
            // bringing it forward is low-commands-tpt.4's work on top of this.
            let into = switch target {
            case .focus: context.frontmostApp
            case .app(let bundleID): bundleID
            }
            let typist = Typist(keyboard: keyboard(into), hotkeys: hotkeys)
            let lowered = try typist.lower(text, on: layout)
            return Step(into: into) { .typed(characters: try typist.type(lowered)) }
        case .sendKeys(let chord):
            let typist = Typist(keyboard: keyboard(context.frontmostApp), hotkeys: hotkeys)
            let lowered = try typist.lower(chord)
            return Step(into: context.frontmostApp) {
                try typist.press(lowered)
                return .pressed(chord)
            }
        case .click(let at, let button, let times):
            let pointer = mouse(context.frontmostApp)
            return Step(into: context.frontmostApp) {
                let click = try pointer.click(at: at, button: button, times: times)
                return .clicked(at: click.at, button: button, times: times, reports: click.reports)
            }
        case .scroll(let at, let vertical, let horizontal):
            let pointer = mouse(context.frontmostApp)
            return Step(into: context.frontmostApp) {
                try pointer.scroll(at: at, vertical: vertical, horizontal: horizontal)
                return .scrolled(at: at, vertical: vertical, horizontal: horizontal)
            }
        case .clickElement(let role, let title):
            let pointer = mouse(context.frontmostApp)
            return Step(into: context.frontmostApp) {
                let click = try pointer.click(element: role, title: title)
                return .clicked(at: click.at, button: .left, times: .single, reports: click.reports)
            }
        case .activateApp, .openURL, .runShortcut, .pipe:
            throw NotAnInput(action: action)
        }
    }
}

private extension Clicks {
    var spelled: String {
        switch rawValue {
        case 1: "once"
        case 2: "twice"
        default: "\(rawValue) times"
        }
    }
}

/// A list that stopped part way: the action that stopped is the cause, and the actions
/// before it are done and cannot be taken back, so they travel with it. Text is in the
/// document either way; what this adds is which of it, so a retry does not type it twice.
public struct RouteStopped: Error, CustomStringConvertible {
    public let performed: [Executor.Performed]
    public let cause: any Error

    public init(performed: [Executor.Performed], cause: any Error) {
        self.performed = performed
        self.cause = cause
    }

    public var description: String {
        let before = performed.isEmpty ? "" : ". Performed before it: " + performed.map(\.description).joined(separator: "; ")
        return "\(cause)\(before)"
    }
}

/// An action neither device can perform. Activating an app, opening a URL, running a
/// shortcut and piping are the command layer's work, and a route that emits one reaches
/// an executor that does not have it yet. [LAW:no-silent-failure] Said by name rather
/// than skipped, so a route is never half-performed without a word.
public struct NotAnInput: Error, CustomStringConvertible {
    public let action: Action

    public var description: String { "neither the keyboard nor the mouse can perform \(action); nothing was done" }
}
