import Foundation
import KeyboardLayout
import LowTalkerCore
import os

/// Performs a route's actions as keystrokes: text typed into the app it names, chords
/// pressed in the app in front.
///
/// [LAW:effects-at-boundaries] The router hands back descriptions; this is the edge
/// where they become key reports. The keyboard is a value it is given per target - the
/// helper behind a focus check in the app, a refusing fake in a test - so the executor
/// itself decides only which app each action means and how much of it was typed.
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

    private let keyboard: Keyboards
    private let hotkeys: Set<KeyChord>
    private let log: Logger

    /// `hotkeys` are the chords the tap listens for, which no action may press.
    public init(keyboard: @escaping Keyboards, hotkeys: Set<KeyChord>, log: Logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "lowtalker", category: "typist")) {
        self.keyboard = keyboard
        self.hotkeys = hotkeys
        self.log = log
    }

    /// One action, done. The time is from the hotkey's key-up to the helper's
    /// acknowledgement of the last release, which is the number the app has to keep
    /// under its latency target and not a claim that the text is on screen: the daemon
    /// acknowledges reports the driver then drops, and reading the screen back is the
    /// CLI's measurement.
    public struct Performed: CustomStringConvertible {
        public enum What {
            case typed(characters: Int)
            case pressed(KeyChord)
        }

        public let what: What
        public let into: BundleID
        public let acknowledged: Duration

        public var description: String {
            let act = switch what {
            case .typed(let characters): "typed \(characters) characters"
            case .pressed(let chord): "pressed \(chord.spelled)"
            }
            return "\(act) into \(into.rawValue), key-up to acknowledged \(Int(acknowledged / .milliseconds(1))) ms"
        }
    }

    /// Performs every action in order, each logged as it completes, and answers with
    /// what was done. Throws before the first key when any action is not a keystroke,
    /// cannot be typed on the layout, or would press the hotkey; throws `TypingStopped`
    /// or `ChordStopped` from the action that stopped, with the earlier ones done.
    @discardableResult
    public func perform(_ actions: [Action], in context: Context, on layout: KeyboardLayout, since keyUp: ContinuousClock.Instant) throws -> [Performed] {
        let lowered = try actions.map { try lower($0, in: context, on: layout) }
        let clock = ContinuousClock()
        return try lowered.map { keystrokes in
            let what = try keystrokes.perform()
            let performed = Performed(what: what, into: keystrokes.into, acknowledged: clock.now - keyUp)
            log.info("\(performed.description, privacy: .public)")
            return performed
        }
    }

    /// An action as keystrokes on the typist for its target, proven before any is pressed.
    private struct Keystrokes {
        let into: BundleID
        let perform: () throws -> Performed.What
    }

    private func lower(_ action: Action, in context: Context, on layout: KeyboardLayout) throws -> Keystrokes {
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
            return Keystrokes(into: into) { .typed(characters: try typist.type(lowered)) }
        case .sendKeys(let chord):
            let typist = Typist(keyboard: keyboard(context.frontmostApp), hotkeys: hotkeys)
            let lowered = try typist.lower(chord)
            return Keystrokes(into: context.frontmostApp) {
                try typist.press(lowered)
                return .pressed(chord)
            }
        case .activateApp, .openURL, .runShortcut, .pipe:
            throw NotAKeystroke(action: action)
        }
    }
}

/// An action the keyboard cannot perform. Activating an app, opening a URL, running a
/// shortcut and piping are the command layer's work, and a route that emits one reaches
/// an executor that does not have it yet. [LAW:no-silent-failure] Said by name rather
/// than skipped, so a route is never half-performed without a word.
public struct NotAKeystroke: Error, CustomStringConvertible {
    public let action: Action

    public var description: String { "the keyboard cannot perform \(action); nothing was typed" }
}
