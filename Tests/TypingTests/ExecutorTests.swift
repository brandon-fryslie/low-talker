import CoreGraphics
import Flavors
import Foundation
import KeyboardLayout
import Keystrokes
import LowTalkerCore
import Testing
import Typing

/// The executor against keyboards the test hands out per app, so which app each action
/// was typed into is read off which keyboard was asked for.
@Suite @MainActor struct ExecutorTests {
    static let us = try! KeyboardLayout.named("com.apple.keylayout.US")
    static let textEdit = BundleID(rawValue: "com.apple.TextEdit")
    static let slack = BundleID(rawValue: "com.tinyspeck.slackmacgap")
    /// Which installation's chord is beside the point here - these are about what the
    /// executor types, not about who held what - so one of them is named once and both
    /// the context and the guard read it from here. [LAW:one-source-of-truth]
    static let held = Hotkey.defaultChord(for: .release)
    static let context = Context(chord: held, press: .hold, frontmostApp: textEdit, focusedElementRole: nil)

    /// One keyboard per app, made on first ask and kept, so the log of every action into
    /// an app is one log.
    @MainActor
    final class Keyboards {
        private(set) var byApp: [BundleID: RefusingKeyboard] = [:]

        func keyboard(for app: BundleID) -> any Keyboard {
            if let keyboard = byApp[app] { return keyboard }
            let keyboard = RefusingKeyboard()
            byApp[app] = keyboard
            return keyboard
        }

        func log(_ app: BundleID) -> [String] { byApp[app]?.log ?? [] }
    }

    /// One mouse per app, kept the same way. Each starts with the cursor at the origin
    /// and a Cancel button on screen, so a click test reads as a dialog being answered.
    @MainActor
    final class Pointers {
        static let cancel = CGRect(x: 641, y: 460, width: 113, height: 30)
        private(set) var byApp: [BundleID: FakeMouse] = [:]

        func pointer(for app: BundleID) -> Pointer {
            if let mouse = byApp[app] { return mouse.pointer }
            let mouse = FakeMouse(at: ScreenPoint(x: 0, y: 0))
            mouse.elements["AXButton/Cancel"] = Self.cancel
            byApp[app] = mouse
            return mouse.pointer
        }

        func log(_ app: BundleID) -> [String] { byApp[app]?.log ?? [] }
    }

    private func executor(_ keyboards: Keyboards, _ pointers: Pointers = Pointers()) -> Executor {
        Executor(keyboard: keyboards.keyboard(for:), mouse: pointers.pointer(for:), hotkeys: [Self.held])
    }

    @Test func textAtTheFocusGoesIntoTheAppThatWasInFront() async throws {
        let keyboards = Keyboards()
        let performed = try await executor(keyboards).perform([.insertText(text: "hi", target: .focus)], in: Self.context, on: Self.us, since: .now)
        #expect(Set(keyboards.byApp.keys) == [Self.textEdit])
        #expect(keyboards.log(Self.textEdit) == ["check", "down b", "up", "check", "down c", "up"])
        #expect(performed.count == 1)
        #expect(performed[0].into == Self.textEdit)
        guard case .typed(let characters) = performed[0].what else { Issue.record("not typed"); return }
        #expect(characters == 2)
        #expect("\(performed[0])".hasPrefix("typed 2 characters into com.apple.TextEdit, key-up to acknowledged "))
    }

    /// A named target is typed into as named, whatever was in front.
    @Test func textForANamedAppGoesIntoThatApp() async throws {
        let keyboards = Keyboards()
        try await executor(keyboards).perform([.insertText(text: "a", target: .app(bundleID: Self.slack))], in: Self.context, on: Self.us, since: .now)
        #expect(Set(keyboards.byApp.keys) == [Self.slack])
        #expect(keyboards.log(Self.slack) == ["check", "down 4", "up"])
    }

    @Test func aChordIsPressedInTheAppThatWasInFront() async throws {
        let keyboards = Keyboards()
        let performed = try await executor(keyboards).perform([.sendKeys(chord: KeyChord(key: Key(rawValue: 0x24)))], in: Self.context, on: Self.us, since: .now)
        #expect(keyboards.log(Self.textEdit) == ["check", "down 28", "up"])
        #expect("\(performed[0])".hasPrefix("pressed key 0x24 into com.apple.TextEdit"))
    }

    /// A click goes to the app that was in front, on the mouse for that app: the cursor
    /// is already at the point, so no motion report precedes the button.
    @Test func aClickIsMadeInTheAppThatWasInFront() async throws {
        let keyboards = Keyboards()
        let pointers = Pointers()
        let performed = try await executor(keyboards, pointers).perform([.click(at: ScreenPoint(x: 0, y: 0), button: .right, times: .double)], in: Self.context, on: Self.us, since: .now)
        #expect(Set(pointers.byApp.keys) == [Self.textEdit])
        #expect(keyboards.byApp.isEmpty)
        #expect(pointers.log(Self.textEdit) == ["check", "check", "down 2", "up", "check", "down 2", "up"])
        #expect("\(performed[0])".hasPrefix("clicked right twice at (0, 0) after 0 move reports into com.apple.TextEdit"))
    }

    /// An element is clicked at the centre of its frame, and a scroll rolls the wheel
    /// where it was asked; both report where the cursor went.
    @Test func anElementIsClickedAtItsCentreAndAScrollRollsTheWheel() async throws {
        let keyboards = Keyboards()
        let pointers = Pointers()
        let centre = ScreenPoint(x: 697.5, y: 475)
        _ = pointers.pointer(for: Self.textEdit)
        pointers.byApp[Self.textEdit]!.position = centre
        let performed = try await executor(keyboards, pointers).perform([
            .clickElement(role: AccessibilityRole(rawValue: "AXButton"), title: "Cancel"),
            .scroll(at: centre, vertical: WheelCounts(rawValue: 3)!, horizontal: .none),
        ], in: Self.context, on: Self.us, since: .now)
        #expect(pointers.log(Self.textEdit) == ["check", "check", "down 1", "up", "check", "check", "scroll 3 0"])
        #expect("\(performed[0])".hasPrefix("clicked left once at (697.5, 475) after 0 move reports into com.apple.TextEdit"))
        #expect("\(performed[1])".hasPrefix("scrolled vertical 3 horizontal 0 at (697.5, 475) into com.apple.TextEdit"))
    }

    @Test func actionsArePerformedInOrder() async throws {
        let keyboards = Keyboards()
        let performed = try await executor(keyboards).perform([
            .insertText(text: "a", target: .focus),
            .sendKeys(chord: KeyChord(key: Key(rawValue: 0x24))),
            .insertText(text: "b", target: .focus),
        ], in: Self.context, on: Self.us, since: .now)
        #expect(keyboards.log(Self.textEdit) == ["check", "down 4", "up", "check", "down 28", "up", "check", "down 5", "up"])
        #expect(performed.count == 3)
    }

    /// The whole list is refused before the first report: an action neither device can
    /// perform anywhere in it means nothing before it is done either.
    @Test func aListWithAnActionThatIsNotAnInputIsRefusedWhole() async throws {
        let keyboards = Keyboards()
        let refused = try await #require(throws: NotAnInput.self) {
            try await executor(keyboards).perform([
                .insertText(text: "a", target: .focus),
                .openURL(url: URL(string: "https://example.com")!),
            ], in: Self.context, on: Self.us, since: .now)
        }
        #expect(refused.action == .openURL(url: URL(string: "https://example.com")!))
        #expect(keyboards.log(Self.textEdit).isEmpty)
    }

    @Test func aListWithTextTheLayoutCannotTypeIsRefusedWhole() async throws {
        let keyboards = Keyboards()
        await #expect(throws: UntypeableCharacters.self) {
            try await executor(keyboards).perform([
                .insertText(text: "a", target: .focus),
                .insertText(text: "\u{1F600}", target: .focus),
            ], in: Self.context, on: Self.us, since: .now)
        }
        #expect(keyboards.log(Self.textEdit).isEmpty)
    }

    @Test func aChordThatWouldPressTheHotkeyIsRefusedWhole() async throws {
        let keyboards = Keyboards()
        await #expect(throws: WouldPressTheHotkey.self) {
            try await executor(keyboards).perform([
                .insertText(text: "a", target: .focus),
                .sendKeys(chord: KeyChord(key: Key(rawValue: 0x0E), modifiers: [.rightOption])),
            ], in: Self.context, on: Self.us, since: .now)
        }
        #expect(keyboards.log(Self.textEdit).isEmpty)
    }

    /// An action that stops mid-run throws its own report with the actions before it,
    /// which are done; the ones after it are not started.
    @Test func anActionThatStopsThrowsItsReportAndEndsTheList() async throws {
        let keyboards = Keyboards()
        _ = keyboards.keyboard(for: Self.textEdit)
        keyboards.byApp[Self.textEdit]!.allow = 4
        let stopped = try await #require(throws: RouteStopped.self) {
            try await executor(keyboards).perform([
                .insertText(text: "a", target: .focus),
                .insertText(text: "bc", target: .focus),
                .insertText(text: "d", target: .focus),
            ], in: Self.context, on: Self.us, since: .now)
        }
        let cause = try #require(stopped.cause as? TypingStopped)
        #expect(cause.typed == 0)
        #expect(cause.of == 2)
        #expect(stopped.performed.count == 1)
        #expect("\(stopped.performed[0])".hasPrefix("typed 1 characters into com.apple.TextEdit"))
        #expect("\(stopped)".contains(". Performed before it: typed 1 characters into com.apple.TextEdit"))
        #expect(keyboards.log(Self.textEdit) == ["check", "down 4", "up", "check"])
    }
}
