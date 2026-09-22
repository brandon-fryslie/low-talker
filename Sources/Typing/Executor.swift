import Foundation
import Insertion
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

    /// Where the actions go. [LAW:types-are-the-program] One value, so an executor that
    /// copies holds no keyboard it could reach for, and one that types holds no clipboard.
    private enum Output {
        /// `hotkeys` are the chords the tap listens for, which no action may press.
        case devices(keyboard: Keyboards, mouse: Pointers, hotkeys: Set<KeyChord>)
        case clipboard(Clipboard)
        /// The input method puts the words at the cursor itself; the clipboard is where
        /// they go when the cursor certainly did not get them. Both, because a cursor that
        /// did not take the words is not the words being gone. [LAW:no-silent-failure]
        case insertion(any Inserter, clipboard: Clipboard)
    }

    private let output: Output
    private let log: Logger

    /// `hotkeys` are the chords the tap listens for, which no action may press.
    public init(keyboard: @escaping Keyboards, mouse: @escaping Pointers, hotkeys: Set<KeyChord>, log: Logger = Executor.log) {
        output = .devices(keyboard: keyboard, mouse: mouse, hotkeys: hotkeys)
        self.log = log
    }

    /// Text at the focus left on the clipboard for the user to paste; nothing typed or
    /// clicked. Nothing here can press a key, so there is no hotkey to refuse.
    public init(copyingTo clipboard: Clipboard, log: Logger = Executor.log) {
        output = .clipboard(clipboard)
        self.log = log
    }

    /// Text at the focus asked of the input method, which commits it at the cursor through
    /// the text input system - no key posted, no pasteboard touched, and no grant asked of
    /// an administrator.
    ///
    /// `clipboard` is not a fallback for everything that can go wrong, and the line it is
    /// drawn on is whether the words certainly did not land. A refusal is that - the input
    /// method looked and there was nowhere to put them - and so is no input method
    /// answering, which is what an uninstalled or unselected bundle looks like and the
    /// likeliest thing that goes wrong here. Those go to the clipboard and the outcome says
    /// both halves, so the icon shows words waiting and the Insert Dictation service can
    /// still place them.
    ///
    /// A channel that broke where this end cannot see which side of the commit it broke on
    /// is thrown as it is, the way an unreachable helper is. Copying there would risk
    /// delivering a second copy of a sentence already in the document, and it would hide a
    /// broken channel behind a working-looking dictation. `Unreachable` carries that split
    /// in its own shape, so this is a fact the compiler holds rather than a rule this
    /// comment asks to be remembered. [LAW:no-silent-failure]
    public init(insertingThrough inserter: any Inserter, orCopyingTo clipboard: Clipboard, log: Logger = Executor.log) {
        output = .insertion(inserter, clipboard: clipboard)
        self.log = log
    }

    nonisolated public static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "lowtalker", category: "typist")

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
            /// Left on the clipboard, where the user pastes it: `into` is the app that was
            /// in front, not an app the text reached. The words themselves, because a copy is
            /// something the user can still ask for, through the Insert Dictation service.
            case copied(String)
            /// Committed at the cursor by the input method. The app is `into`, which for
            /// this case is the app the words actually reached and not necessarily the one
            /// this route was decided in front of: the person can move between the chord and
            /// the words being ready, and the input method commits where the cursor is then.
            /// Less than a person seeing them, and more than `copied` can say.
            /// [FRAMING:representation]
            case inserted(characters: Int)
            /// The cursor did not get them, so they are on the clipboard instead. Both halves
            /// in one outcome, because why the cursor did not get the words and where they
            /// are now are two facts and neither answers the other.
            case notInserted(NotAtTheCursor, copied: String)
        }

        public let what: What
        /// The app this outcome is about, which each case above says its own relation to:
        /// the app typed into, the app a click landed in, the app in front while words went
        /// to the clipboard, the app whose cursor took an insert. One field and not one per
        /// case, so a reader of a list of these - the session line - has one place to look
        /// and cannot be handed two apps that disagree. [LAW:one-source-of-truth]
        public let into: BundleID
        public let acknowledged: Duration

        public var description: String {
            let act = switch what {
            case .typed(let characters): "typed \(characters) characters into \(into.rawValue)"
            case .pressed(let chord): "pressed \(Hotkey.held(chord)) into \(into.rawValue)"
            case .clicked(let at, let button, let times, let reports): "clicked \(button.rawValue) \(times.spelled) at \(at) after \(reports) move reports into \(into.rawValue)"
            case .scrolled(let at, let vertical, let horizontal): "scrolled vertical \(vertical.rawValue) horizontal \(horizontal.rawValue) at \(at) into \(into.rawValue)"
            case .copied(let text): "copied \(text.count) characters to the clipboard with \(into.rawValue) in front"
            case .inserted(let characters): "inserted \(characters) characters at the cursor in \(into.rawValue)"
            case .notInserted(let reason, let text): "\(reason), so \(text.count) characters went to the clipboard with \(into.rawValue) in front"
            }
            return "\(act), key-up to acknowledged \(Int(acknowledged / .milliseconds(1))) ms"
        }
    }

    /// Performs every action in order, each logged as it completes, and answers with
    /// what was done. Throws before the first report when any action is one the devices
    /// cannot perform, cannot be typed on the layout, or would press the hotkey; throws
    /// `RouteStopped` from the action that stopped, carrying the earlier ones, which are
    /// done.
    ///
    /// `frontmost` is the app that was in front when the actions were decided: where text at
    /// the focus goes, and where chords and clicks land. It is the one fact about that moment
    /// an executor reads, so it is the one it is handed - a whole `Context` asked a caller
    /// with no hotkey behind it, `lowtalker type`, to invent the chord that started it.
    /// [LAW:types-are-the-program]
    ///
    /// `layout` is read only by an executor that types: copying needs no layout, so a
    /// layout that cannot be read costs the clipboard nothing.
    @discardableResult
    public func perform(_ actions: [Action], in frontmost: BundleID, on layout: @autoclosure () throws -> KeyboardLayout, since keyUp: ContinuousClock.Instant) async throws -> [Performed] {
        let lowered: [Step]
        switch output {
        case .devices(let keyboard, let mouse, let hotkeys):
            let layout = try layout()
            lowered = try actions.map { try lower($0, in: frontmost, on: layout, keyboard: keyboard, mouse: mouse, hotkeys: hotkeys) }
        case .clipboard(let clipboard):
            lowered = try actions.map { try copy($0, in: frontmost, to: clipboard) }
        case .insertion(let inserter, let clipboard):
            lowered = try actions.map { try insert($0, in: frontmost, through: inserter, orTo: clipboard) }
        }
        let clock = ContinuousClock()
        var performed: [Performed] = []
        for step in lowered {
            let landed: (what: Performed.What, into: BundleID)
            do { landed = try await step.perform() } catch { throw RouteStopped(performed: performed, cause: error) }
            let done = Performed(what: landed.what, into: landed.into, acknowledged: clock.now - keyUp)
            log.info("\(done.description, privacy: .public)")
            performed.append(done)
        }
        return performed
    }

    /// An action as reports on the device for its target, proven before any is posted.
    ///
    /// The app comes back with the outcome rather than being fixed when the step is built.
    /// An insert only learns which app took the words when the input method names it, and a
    /// step that carried the app it was aimed at would leave `Performed` holding that beside
    /// the one it reached - two apps, free to disagree, with the session line reading one
    /// and the action line the other. [LAW:one-source-of-truth] Every other step answers
    /// with the app it was built for, which is the same shape and needs no case of its own.
    /// [LAW:dataflow-not-control-flow]
    private struct Step {
        let perform: @MainActor () async throws -> (what: Performed.What, into: BundleID)
    }

    private func copy(_ action: Action, in frontmost: BundleID, to clipboard: Clipboard) throws -> Step {
        switch action {
        case .insertText(let text, .focus):
            return Step {
                try clipboard.write(text)
                return (.copied(text), frontmost)
            }
        // Text for a named app included: the clipboard reaches whatever the user pastes
        // into, so an action that names its app is one this output would only pretend to.
        case .insertText(_, .app), .sendKeys, .click, .scroll, .clickElement:
            throw NeedsTheVirtualKeyboard(action: action, instead: "puts dictation on the clipboard")
        case .activateApp, .openURL, .runShortcut, .pipe:
            throw NotAnInput(action: action)
        }
    }

    private func insert(_ action: Action, in frontmost: BundleID, through inserter: any Inserter, orTo clipboard: Clipboard) throws -> Step {
        switch action {
        case .insertText(let text, .focus):
            return Step {
                // The one thing that ends at the cursor returns; everything else names why
                // it did not and leaves by the single road to the clipboard below.
                // [LAW:dataflow-not-control-flow]
                let reason: NotAtTheCursor
                do {
                    // Awaited, so the round trip runs on a thread of its own: this is the
                    // main actor, and `Inserter` says in its own contract that the blocking
                    // call must not pump it. [LAW:no-ambient-temporal-coupling]
                    switch try await inserter.insert(text) {
                    case .inserted(let characters, let reached):
                        return (.inserted(characters: characters), BundleID(rawValue: reached))
                    // Not a failure to recover from but the other half of this output's job:
                    // the input method looked and there was nowhere to put words.
                    case .refused(let refusal):
                        reason = .refused(refusal)
                    }
                } catch let unreachable as Unreachable {
                    switch unreachable {
                    // The channel saying the cursor never saw the words. Not installed and
                    // not selected are this case, and they are the likeliest thing that goes
                    // wrong here, so the utterance goes where the person can still reach it
                    // rather than existing only in a log line.
                    case .didNotLand(let why):
                        reason = .noInputMethod(why)
                    // Thrown on untouched: here the far end may already have put the words
                    // in the document, and words that may have landed must not be delivered
                    // a second time. The type makes that the only thing this arm can do.
                    // [LAW:no-silent-failure]
                    case .mayHaveLanded:
                        throw unreachable
                    }
                }
                // Both facts or neither: a pasteboard that will not take the words would
                // otherwise replace the reason with its own complaint, and the person would
                // be told where the words are not without being told why the cursor did not
                // get them. [LAW:no-silent-failure]
                do { try clipboard.write(text) } catch { throw NotInsertedAndNotCopied(reason: reason, cause: error) }
                return (.notInserted(reason, copied: text), frontmost)
            }
        // Text for a named app included: this output reaches the cursor the text input
        // system is holding, which belongs to whatever is in front, so an action naming its
        // own app is one it could only pretend to perform.
        case .insertText(_, .app), .sendKeys, .click, .scroll, .clickElement:
            throw NeedsTheVirtualKeyboard(action: action, instead: "asks the input method to put dictation at the cursor")
        case .activateApp, .openURL, .runShortcut, .pipe:
            throw NotAnInput(action: action)
        }
    }

    private func lower(_ action: Action, in frontmost: BundleID, on layout: KeyboardLayout, keyboard: Keyboards, mouse: Pointers, hotkeys: Set<KeyChord>) throws -> Step {
        switch action {
        case .insertText(let text, let target):
            // The focus is whatever app was in front when the actions were decided;
            // typing into it re-proves it in front before every key. A named app is
            // typed into the same way, without being raised: bringing it forward is
            // low-commands-tpt.4's work on top of this.
            let into = switch target {
            case .focus: frontmost
            case .app(let bundleID): bundleID
            }
            let typist = Typist(keyboard: keyboard(into), hotkeys: hotkeys)
            let lowered = try typist.lower(text, on: layout)
            return Step { (.typed(characters: try await typist.type(lowered)), into) }
        case .sendKeys(let chord):
            let typist = Typist(keyboard: keyboard(frontmost), hotkeys: hotkeys)
            let lowered = try typist.lower(chord)
            return Step {
                try await typist.press(lowered)
                return (.pressed(chord), frontmost)
            }
        case .click(let at, let button, let times):
            let pointer = mouse(frontmost)
            return Step {
                let click = try await pointer.click(at: at, button: button, times: times)
                return (.clicked(at: click.at, button: button, times: times, reports: click.reports), frontmost)
            }
        case .scroll(let at, let vertical, let horizontal):
            let pointer = mouse(frontmost)
            return Step {
                try await pointer.scroll(at: at, vertical: vertical, horizontal: horizontal)
                return (.scrolled(at: at, vertical: vertical, horizontal: horizontal), frontmost)
            }
        case .clickElement(let role, let title):
            let pointer = mouse(frontmost)
            return Step {
                let click = try await pointer.click(element: role, title: title)
                return (.clicked(at: click.at, button: .left, times: .single, reports: click.reports), frontmost)
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
public struct RouteStopped: StoppedPartWay, CustomStringConvertible {
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

/// The words did not reach the cursor and the clipboard would not take them either, which
/// is two failures and one outcome: where the words could not go, and that they are now
/// nowhere. Carried together because the reason is the half that says what to fix.
/// [LAW:no-silent-failure]
public struct NotInsertedAndNotCopied: Error, CustomStringConvertible {
    public let reason: NotAtTheCursor
    public let cause: any Error

    public var description: String { "\(reason), and the words could not be copied either: \(cause)" }
}

/// An action neither device can perform. Activating an app, opening a URL, running a
/// shortcut and piping are the command layer's work, and a route that emits one reaches
/// an executor that does not have it yet. [LAW:no-silent-failure] Said by name rather
/// than skipped, so a route is never half-performed without a word.
public struct NotAnInput: Error, CustomStringConvertible {
    public let action: Action

    public var description: String { "neither the keyboard nor the mouse can perform \(action); nothing was done" }
}

/// An action only the virtual keyboard or mouse can perform, reaching an executor that has
/// neither. [LAW:no-silent-failure] Refused by name, so a route that needs the devices says
/// so instead of leaving part of itself somewhere the user did not ask for.
public struct NeedsTheVirtualKeyboard: Error, CustomStringConvertible {
    public let action: Action
    /// What this installation does with dictated words instead, in the words that output's
    /// own line would use. A value rather than a second error type, because what differs
    /// between the outputs is this sentence and not the refusal.
    /// [LAW:dataflow-not-control-flow]
    public let instead: String

    public var description: String { "\(action) needs the virtual keyboard, and this installation \(instead); nothing was done" }
}
