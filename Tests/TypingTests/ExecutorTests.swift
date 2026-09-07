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
    static let context = Context(chord: Hotkey.defaultChord, press: .hold, frontmostApp: textEdit, focusedElementRole: nil)

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

    private func executor(_ keyboards: Keyboards) -> Executor {
        Executor(keyboard: keyboards.keyboard(for:), hotkeys: [Hotkey.defaultChord])
    }

    @Test func textAtTheFocusGoesIntoTheAppThatWasInFront() throws {
        let keyboards = Keyboards()
        let performed = try executor(keyboards).perform([.insertText(text: "hi", target: .focus)], in: Self.context, on: Self.us, since: .now)
        #expect(Set(keyboards.byApp.keys) == [Self.textEdit])
        #expect(keyboards.log(Self.textEdit) == ["check", "down b", "up", "check", "down c", "up"])
        #expect(performed.count == 1)
        #expect(performed[0].into == Self.textEdit)
        guard case .typed(let characters) = performed[0].what else { Issue.record("not typed"); return }
        #expect(characters == 2)
        #expect("\(performed[0])".hasPrefix("typed 2 characters into com.apple.TextEdit, key-up to acknowledged "))
    }

    /// A named target is typed into as named, whatever was in front.
    @Test func textForANamedAppGoesIntoThatApp() throws {
        let keyboards = Keyboards()
        try executor(keyboards).perform([.insertText(text: "a", target: .app(bundleID: Self.slack))], in: Self.context, on: Self.us, since: .now)
        #expect(Set(keyboards.byApp.keys) == [Self.slack])
        #expect(keyboards.log(Self.slack) == ["check", "down 4", "up"])
    }

    @Test func aChordIsPressedInTheAppThatWasInFront() throws {
        let keyboards = Keyboards()
        let performed = try executor(keyboards).perform([.sendKeys(chord: KeyChord(key: Key(rawValue: 0x24)))], in: Self.context, on: Self.us, since: .now)
        #expect(keyboards.log(Self.textEdit) == ["check", "down 28", "up"])
        #expect("\(performed[0])".hasPrefix("pressed key 0x24 into com.apple.TextEdit"))
    }

    @Test func actionsArePerformedInOrder() throws {
        let keyboards = Keyboards()
        let performed = try executor(keyboards).perform([
            .insertText(text: "a", target: .focus),
            .sendKeys(chord: KeyChord(key: Key(rawValue: 0x24))),
            .insertText(text: "b", target: .focus),
        ], in: Self.context, on: Self.us, since: .now)
        #expect(keyboards.log(Self.textEdit) == ["check", "down 4", "up", "check", "down 28", "up", "check", "down 5", "up"])
        #expect(performed.count == 3)
    }

    /// The whole list is refused before the first key: an action the keyboard cannot
    /// perform anywhere in it means nothing before it is typed either.
    @Test func aListWithAnActionThatIsNotAKeystrokeIsRefusedWhole() throws {
        let keyboards = Keyboards()
        let refused = try #require(throws: NotAKeystroke.self) {
            try executor(keyboards).perform([
                .insertText(text: "a", target: .focus),
                .openURL(url: URL(string: "https://example.com")!),
            ], in: Self.context, on: Self.us, since: .now)
        }
        #expect(refused.action == .openURL(url: URL(string: "https://example.com")!))
        #expect(keyboards.log(Self.textEdit).isEmpty)
    }

    @Test func aListWithTextTheLayoutCannotTypeIsRefusedWhole() throws {
        let keyboards = Keyboards()
        #expect(throws: UntypeableCharacters.self) {
            try executor(keyboards).perform([
                .insertText(text: "a", target: .focus),
                .insertText(text: "\u{1F600}", target: .focus),
            ], in: Self.context, on: Self.us, since: .now)
        }
        #expect(keyboards.log(Self.textEdit).isEmpty)
    }

    @Test func aChordThatWouldPressTheHotkeyIsRefusedWhole() throws {
        let keyboards = Keyboards()
        #expect(throws: WouldPressTheHotkey.self) {
            try executor(keyboards).perform([
                .insertText(text: "a", target: .focus),
                .sendKeys(chord: KeyChord(key: Key(rawValue: 0x0E), modifiers: [.rightOption])),
            ], in: Self.context, on: Self.us, since: .now)
        }
        #expect(keyboards.log(Self.textEdit).isEmpty)
    }

    /// An action that stops mid-run throws its own report with the actions before it,
    /// which are done; the ones after it are not started.
    @Test func anActionThatStopsThrowsItsReportAndEndsTheList() throws {
        let keyboards = Keyboards()
        _ = keyboards.keyboard(for: Self.textEdit)
        keyboards.byApp[Self.textEdit]!.allow = 4
        let stopped = try #require(throws: RouteStopped.self) {
            try executor(keyboards).perform([
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
