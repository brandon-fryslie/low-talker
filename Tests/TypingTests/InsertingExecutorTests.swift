import AppKit
import CoreGraphics
import Foundation
import Insertion
import KeyboardLayout
import Keystrokes
import LowTalkerCore
import Pointing
import Testing
@testable import Typing

/// The executor's third output: the words are asked of the input method, and what it will
/// not take goes to the clipboard instead.
///
/// [LAW:behavior-not-structure] Asked through `Inserter`, which is one method and mentions
/// no port and no macOS - so every case here runs with no second process, no input source
/// selected, and nothing at a real cursor. What cannot be asked of a double is whether the
/// words appear in a window, and that is low-input-method-s71.48t's live checkpoint, not a
/// thing to mock an answer to.
@Suite @MainActor struct InsertingExecutorTests {
    static let us = try! KeyboardLayout.named("com.apple.keylayout.US")
    /// `nonisolated` where the suite is not: a bundle id is a value, and the double that
    /// names one is asked on a thread of the executor's choosing rather than on this actor.
    nonisolated static let textEdit = BundleID(rawValue: "com.apple.TextEdit")
    nonisolated static let slack = BundleID(rawValue: "com.tinyspeck.slackmacgap")

    /// An input method that answers however the case needs and remembers what it was asked.
    ///
    /// Locked and `@unchecked Sendable` because it is asked on a thread of the executor's
    /// choosing: `Inserter`'s awaited overload puts the blocking call on a thread of its
    /// own, which is the whole reason the executor can ask from the main actor at all.
    private final class AnInputMethod: Inserter, @unchecked Sendable {
        private let lock = NSLock()
        private let answering: @Sendable (String) throws -> InsertionAnswer
        private var asked: [String] = []

        init(_ answering: @escaping @Sendable (String) throws -> InsertionAnswer) {
            self.answering = answering
        }

        var texts: [String] {
            lock.withLock { asked }
        }

        func insert(_ text: String) throws -> InsertionAnswer {
            lock.withLock { asked.append(text) }
            return try answering(text)
        }
    }

    /// A pasteboard of the test's own, so a run never touches the clipboard of the person at
    /// this Mac, released when the test ends.
    private func withPasteboard(_ body: (NSPasteboard) async throws -> Void) async rethrows {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("lowtalker.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("what was there", forType: .string)
        try await body(pasteboard)
    }

    /// The words reach the cursor and the clipboard is not touched on the way: the whole
    /// reason this delivery exists is that the person's own clipboard survives a dictation.
    @Test func wordsAtTheFocusAreInsertedAtTheCursor() async throws {
        try await withPasteboard { pasteboard in
            let inputMethod = AnInputMethod { .inserted(characters: $0.count, into: Self.textEdit.rawValue) }
            let performed = try await Executor(insertingThrough: inputMethod, orCopyingTo: Clipboard(pasteboard))
                .perform([.insertText(text: "héllo there", target: .focus)], in: Self.textEdit, on: Self.us, since: .now)

            #expect(inputMethod.texts == ["héllo there"])
            #expect(pasteboard.string(forType: .string) == "what was there")
            #expect(performed.count == 1)
            #expect(performed[0].into == Self.textEdit)
            guard case .inserted(let characters, let reached) = performed[0].what else { Issue.record("not inserted"); return }
            #expect(characters == 11)
            #expect(reached == Self.textEdit)
            #expect("\(performed[0])".hasPrefix("inserted 11 characters at the cursor in com.apple.TextEdit, key-up to acknowledged "))
        }
    }

    /// The app the outcome names is the app the input method says it reached, which is not
    /// always the one this route was decided in front of: the person holds the chord in one
    /// window and is somewhere else by the time the words are ready, and the input method
    /// commits where the cursor is then. Naming the remembered app would be a log line
    /// pointing at the wrong window. [FRAMING:representation]
    @Test func theAppNamedIsTheOneTheInputMethodReached() async throws {
        try await withPasteboard { pasteboard in
            let inputMethod = AnInputMethod { .inserted(characters: $0.count, into: Self.slack.rawValue) }
            let performed = try await Executor(insertingThrough: inputMethod, orCopyingTo: Clipboard(pasteboard))
                .perform([.insertText(text: "hi", target: .focus)], in: Self.textEdit, on: Self.us, since: .now)

            guard case .inserted(_, let reached) = performed[0].what else { Issue.record("not inserted"); return }
            #expect(reached == Self.slack)
            #expect("\(performed[0])".hasPrefix("inserted 2 characters at the cursor in com.tinyspeck.slackmacgap, key-up to acknowledged "))
        }
    }

    /// Every refusal, because a refusal is an answer this output acts on rather than a
    /// failure it recovers from, and the words are never lost to one: they go where the
    /// person can still reach them and the outcome carries the reason they are there.
    ///
    /// Over every case rather than the one the ticket names, so a refusal added later is
    /// covered by the compiler rather than by whoever remembers this file.
    @Test(arguments: Refusal.allCases)
    func aRefusalLeavesTheWordsOnTheClipboardAndSaysBoth(refusal: Refusal) async throws {
        try await withPasteboard { pasteboard in
            let inputMethod = AnInputMethod { _ in .refused(refusal) }
            let performed = try await Executor(insertingThrough: inputMethod, orCopyingTo: Clipboard(pasteboard))
                .perform([.insertText(text: "héllo there", target: .focus)], in: Self.textEdit, on: Self.us, since: .now)

            #expect(pasteboard.string(forType: .string) == "héllo there")
            #expect(performed.count == 1)
            guard case .refused(let said, let copied) = performed[0].what else { Issue.record("not refused"); return }
            #expect(said == refusal)
            #expect(copied == "héllo there")
            #expect("\(performed[0])".hasPrefix("\(refusal), so 11 characters went to the clipboard with com.apple.TextEdit in front, key-up to acknowledged "))
        }
    }

    /// A transport failure is not an answer about the cursor, so it is not answered like
    /// one: it is thrown, and nothing is copied. Copying here too - "so the words are never
    /// lost" - would leave a broken channel looking like a working dictation, and a failure
    /// nobody sees is a failure nobody fixes. [LAW:no-silent-failure]
    @Test func aTransportFailureThrowsAndCopiesNothing() async throws {
        try await withPasteboard { pasteboard in
            let unreachable = Unreachable.nothingIsListening(port: "ai.promptctl.low-talker.test.insert")
            let inputMethod = AnInputMethod { _ in throw unreachable }
            let stopped = try await #require(throws: RouteStopped.self) {
                try await Executor(insertingThrough: inputMethod, orCopyingTo: Clipboard(pasteboard))
                    .perform([.insertText(text: "héllo there", target: .focus)], in: Self.textEdit, on: Self.us, since: .now)
            }

            #expect(stopped.cause as? Unreachable == unreachable)
            #expect(stopped.performed.isEmpty)
            #expect(pasteboard.string(forType: .string) == "what was there")
        }
    }

    /// The two facts a transport failure and a refusal must never blur into one: the words
    /// may have landed at the cursor, so they are not put on the clipboard for a second
    /// delivery of the same sentence.
    @Test func anAnswerThatNeverArrivedIsNotCopiedEither() async throws {
        try await withPasteboard { pasteboard in
            let unanswered = Unreachable.answerDidNotArrive(port: "ai.promptctl.low-talker.test.insert", after: .seconds(2))
            let inputMethod = AnInputMethod { _ in throw unanswered }
            let stopped = try await #require(throws: RouteStopped.self) {
                try await Executor(insertingThrough: inputMethod, orCopyingTo: Clipboard(pasteboard))
                    .perform([.insertText(text: "héllo there", target: .focus)], in: Self.textEdit, on: Self.us, since: .now)
            }

            #expect(stopped.cause as? Unreachable == unanswered)
            #expect(pasteboard.string(forType: .string) == "what was there")
        }
    }

    /// A pasteboard that will not take the words leaves the person with neither the cursor
    /// nor the clipboard, and both halves of that are said: the refusal is what there is to
    /// fix, and it would otherwise be replaced by the pasteboard's own complaint.
    /// [LAW:no-silent-failure]
    @Test func aClipboardThatRefusesDoesNotSwallowTheRefusal() async throws {
        let refusing = Clipboard { _ in throw ClipboardRefused(pasteboard: "a pasteboard that will not take them") }
        let inputMethod = AnInputMethod { _ in .refused(.noClientHasFocus) }
        let stopped = try await #require(throws: RouteStopped.self) {
            try await Executor(insertingThrough: inputMethod, orCopyingTo: refusing)
                .perform([.insertText(text: "héllo there", target: .focus)], in: Self.textEdit, on: Self.us, since: .now)
        }

        let both = try #require(stopped.cause as? RefusedAndNotCopied)
        #expect(both.refusal == .noClientHasFocus)
        #expect(both.cause is ClipboardRefused)
        #expect("\(both)".hasPrefix("no client has focus, and the words could not be copied either: "))
    }

    /// Everything only the virtual devices can do is refused before anything is sent, so a
    /// list with one of them in it inserts nothing and copies nothing either - and the
    /// refusal names the delivery the person actually has.
    @Test func whatOnlyTheDevicesCanDoIsRefusedByNameAndNothingIsSent() async throws {
        let refused: [Action] = [
            .sendKeys(chord: KeyChord(key: Key(rawValue: 0x24))),
            .click(at: ScreenPoint(x: 1, y: 1), button: .left, times: .single),
            .scroll(at: ScreenPoint(x: 1, y: 1), vertical: WheelCounts(rawValue: 3)!, horizontal: .none),
            .clickElement(role: AccessibilityRole(rawValue: "AXButton"), title: "Cancel"),
            .insertText(text: "a", target: .app(bundleID: Self.slack)),
        ]
        for action in refused {
            try await withPasteboard { pasteboard in
                let inputMethod = AnInputMethod { .inserted(characters: $0.count, into: Self.textEdit.rawValue) }
                let refusal = try await #require(throws: NeedsTheVirtualKeyboard.self) {
                    try await Executor(insertingThrough: inputMethod, orCopyingTo: Clipboard(pasteboard))
                        .perform([.insertText(text: "first", target: .focus), action], in: Self.textEdit, on: Self.us, since: .now)
                }

                #expect("\(refusal)".contains("asks the input method to put dictation at the cursor"))
                #expect(inputMethod.texts.isEmpty, "\(action) let the text before it through to the input method")
                #expect(pasteboard.string(forType: .string) == "what was there", "\(action) let the text before it through to the clipboard")
            }
        }
    }

    /// What no output here can do at all is said the other way, because activating an app or
    /// opening a URL is not something a virtual keyboard would fix either.
    @Test func whatIsNoInputAtAllIsSaidTheOtherWay() async throws {
        try await withPasteboard { pasteboard in
            let inputMethod = AnInputMethod { .inserted(characters: $0.count, into: Self.textEdit.rawValue) }
            await #expect(throws: NotAnInput.self) {
                try await Executor(insertingThrough: inputMethod, orCopyingTo: Clipboard(pasteboard))
                    .perform([.activateApp(bundleID: Self.slack)], in: Self.textEdit, on: Self.us, since: .now)
            }
            #expect(inputMethod.texts.isEmpty)
        }
    }

    /// Inserting reads no layout, the way copying does not: only typing needs to know which
    /// keys make which characters, so a layout that cannot be read costs this output
    /// nothing.
    @Test func insertingReadsNoLayout() async throws {
        struct UnreadableLayout: Error {}
        try await withPasteboard { pasteboard in
            let inputMethod = AnInputMethod { .inserted(characters: $0.count, into: Self.textEdit.rawValue) }
            let performed = try await Executor(insertingThrough: inputMethod, orCopyingTo: Clipboard(pasteboard))
                .perform([.insertText(text: "hi", target: .focus)], in: Self.textEdit,
                         on: { throw UnreadableLayout() }(), since: .now)

            #expect(performed.count == 1)
            #expect(inputMethod.texts == ["hi"])
        }
    }
}
