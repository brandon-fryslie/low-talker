import Foundation
import Insertion
import LowTalkerCore
import Testing
@testable import Dictation

/// The executor: the words are asked of the input method, and what it
/// does not put at the cursor is a failure, thrown by name.
///
/// [LAW:behavior-not-structure] Asked through `Inserter`, which is one method and mentions
/// no port and no macOS - so every case here runs with no second process, no input source
/// selected, and nothing at a real cursor. What cannot be asked of a double is whether the
/// words appear in a window, and that is the live checkpoint, not a thing to mock an answer to.
@Suite @MainActor struct InsertingExecutorTests {
    /// `nonisolated` where the suite is not: a bundle id is a value, and the double that
    /// names one is asked on a thread of the executor's choosing rather than on this actor.
    nonisolated static let textEdit = BundleID(rawValue: "com.apple.TextEdit")
    nonisolated static let slack = BundleID(rawValue: "com.tinyspeck.slackmacgap")
    /// A port nothing is on: every case that names one here is a channel that failed.
    nonisolated static let port = "ai.promptctl.low-talker.test.insert"

    /// An input method that answers however the case needs and remembers what it was asked.
    ///
    /// Locked and `@unchecked Sendable` because it is asked on a thread of the executor's
    /// choosing: `Inserter`'s awaited overload puts the blocking call on a thread of its
    /// own, which is the whole reason the executor can ask from the main actor at all.
    private final class AnInputMethod: Inserter, @unchecked Sendable {
        private let lock = NSLock()
        private let answering: @Sendable (String) throws -> Inserted
        private var asked: [String] = []

        init(_ answering: @escaping @Sendable (String) throws -> Inserted) {
            self.answering = answering
        }

        var texts: [String] {
            lock.withLock { asked }
        }

        func insert(_ text: String) throws -> Inserted {
            lock.withLock { asked.append(text) }
            return try answering(text)
        }
    }

    private static func inserting(into app: BundleID) -> AnInputMethod {
        AnInputMethod { Inserted(characters: $0.count, into: app.rawValue) }
    }

    @Test func wordsAtTheFocusAreInsertedAtTheCursor() async throws {
        let inputMethod = Self.inserting(into: Self.textEdit)
        let performed = try await Executor(insertingThrough: inputMethod)
            .perform([.insertText(text: "héllo there", target: .focus)], since: .now)

        #expect(inputMethod.texts == ["héllo there"])
        #expect(performed.count == 1)
        #expect(performed[0].into == Self.textEdit)
        #expect(performed[0].characters == 11)
        #expect("\(performed[0])".hasPrefix("inserted 11 characters at the cursor in com.apple.TextEdit, key-up to acknowledged "))
    }

    /// The app the outcome names is the app the input method says it reached, which is not
    /// always the one this route was decided in front of: the person holds the chord in one
    /// window and is somewhere else by the time the words are ready, and the input method
    /// commits where the cursor is then. [FRAMING:representation]
    @Test func theAppNamedIsTheOneTheInputMethodReached() async throws {
        let performed = try await Executor(insertingThrough: Self.inserting(into: Self.slack))
            .perform([.insertText(text: "hi", target: .focus)], since: .now)

        #expect(performed[0].into == Self.slack)
        #expect("\(performed[0])".hasPrefix("inserted 2 characters at the cursor in com.tinyspeck.slackmacgap, key-up to acknowledged "))
    }

    /// Every refusal stops the route by name with nothing performed: the words are not at
    /// the cursor, and nothing puts them anywhere else. Over every case, so a refusal added
    /// later is covered by the compiler rather than by whoever remembers this file.
    @Test(arguments: Refusal.allCases)
    func aRefusalStopsTheRouteByName(refusal: Refusal) async throws {
        let inputMethod = AnInputMethod { _ in throw refusal }
        let stopped = try await #require(throws: RouteStopped.self) {
            try await Executor(insertingThrough: inputMethod)
                .perform([.insertText(text: "héllo there", target: .focus)], since: .now)
        }

        #expect(stopped.cause as? Refusal == refusal)
        #expect(stopped.performed.isEmpty)
    }

    /// Words an app has not taken yet stop the route by that name, never as a refusal: they
    /// may still land, and nothing here sends them again.
    @Test func wordsNotYetTakenStopTheRouteByName() async throws {
        let late = NotYetTaken(characters: 11, into: "com.apple.TextEdit")
        let inputMethod = AnInputMethod { _ in throw late }
        let stopped = try await #require(throws: RouteStopped.self) {
            try await Executor(insertingThrough: inputMethod)
                .perform([.insertText(text: "héllo there", target: .focus)], since: .now)
        }

        #expect(stopped.cause as? NotYetTaken == late)
        #expect(stopped.performed.isEmpty)
    }

    /// Every way the channel fails stops the route the same way, by its own name.
    @Test(arguments: [
        Unreachable.nothingIsListening(port: Self.port),
        .requestWasNotTaken(port: Self.port, after: .seconds(2)),
        .answerDidNotArrive(port: Self.port, after: .seconds(2)),
        .didNotSayWhoItIs(port: Self.port, after: .seconds(2)),
        .answerWasAbandoned(port: Self.port),
        .answeredByAStranger(port: Self.port, pid: 42, because: .someoneElse(.adHoc(cdhash: "00")), required: .signed(identifier: "x", certificate: "00"), words: .notSent),
        .failed(port: Self.port, status: -1, words: .mayHaveLanded),
        .answerWasNotReadable(port: Self.port, bytes: 42, words: .mayHaveLanded),
    ])
    func aChannelThatFailsStopsTheRouteByName(why: Unreachable) async throws {
        let inputMethod = AnInputMethod { _ in throw why }
        let stopped = try await #require(throws: RouteStopped.self) {
            try await Executor(insertingThrough: inputMethod)
                .perform([.insertText(text: "héllo there", target: .focus)], since: .now)
        }

        #expect(stopped.cause as? Unreachable == why)
        #expect(stopped.performed.isEmpty)
    }

    /// Everything that is not text at the focus is refused before anything is sent, so a
    /// list with one of them in it inserts nothing. Text for a named app is among them: the
    /// input method reaches only the cursor the text input system is holding.
    @Test func whatIsNotTextAtTheFocusIsRefusedByNameAndNothingIsSent() async throws {
        let refused: [Action] = [
            .insertText(text: "a", target: .app(bundleID: Self.slack)),
            .activateApp(bundleID: Self.slack),
            .openURL(url: URL(string: "https://example.com")!),
            .runShortcut(name: "x", input: nil),
            .pipe(executable: "/bin/cat", arguments: []),
        ]
        for action in refused {
            let inputMethod = Self.inserting(into: Self.textEdit)
            let refusal = try await #require(throws: NotAnInsert.self) {
                try await Executor(insertingThrough: inputMethod)
                    .perform([.insertText(text: "first", target: .focus), action], since: .now)
            }

            #expect(refusal.action == action)
            #expect(inputMethod.texts.isEmpty, "\(action) let the text before it through to the input method")
        }
    }
}
