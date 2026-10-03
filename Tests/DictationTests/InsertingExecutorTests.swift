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
        private var asked: [(text: String, destination: Destination)] = []

        init(_ answering: @escaping @Sendable (String) throws -> Inserted) {
            self.answering = answering
        }

        var texts: [String] {
            lock.withLock { asked.map(\.text) }
        }

        var destinations: [Destination] {
            lock.withLock { asked.map(\.destination) }
        }

        func insert(_ text: String, into destination: Destination) throws -> Inserted {
            lock.withLock { asked.append((text, destination)) }
            return try answering(text)
        }
    }

    private static func inserting(into app: BundleID) -> AnInputMethod {
        AnInputMethod { Inserted(characters: $0.count, into: app.rawValue) }
    }

    @Test func wordsAtTheFocusAreInsertedAtTheCursor() async throws {
        let inputMethod = Self.inserting(into: Self.textEdit)
        let performed = try #require(await Executor(insertingThrough: inputMethod)
            .insert(Transcript(typed: "héllo there"), following: nil, since: .keyUp(.now)))

        #expect(inputMethod.texts == ["héllo there"])
        #expect(performed.into == Self.textEdit)
        #expect(performed.characters == 11)
        #expect("\(performed)".hasPrefix("inserted 11 characters at the cursor in com.apple.TextEdit, key-up to acknowledged "))
    }

    /// The app the outcome names is the app the input method says it reached, which is not
    /// always the one in front at key-down: the person holds the chord in one
    /// window and is somewhere else by the time the words are ready, and the input method
    /// commits where the cursor is then. [FRAMING:representation]
    @Test func theAppNamedIsTheOneTheInputMethodReached() async throws {
        let performed = try #require(await Executor(insertingThrough: Self.inserting(into: Self.slack))
            .insert(Transcript(typed: "hi"), following: nil, since: .keyUp(.now)))

        #expect(performed.into == Self.slack)
        #expect("\(performed)".hasPrefix("inserted 2 characters at the cursor in com.tinyspeck.slackmacgap, key-up to acknowledged "))
    }

    /// A dictation's first words go to the cursor in front, and each insert after them only
    /// to the app the one before it reached.
    @Test func eachInsertIsBoundToTheAppTheOneBeforeItReached() async throws {
        let inputMethod = Self.inserting(into: Self.textEdit)
        let executor = Executor(insertingThrough: inputMethod)
        let first = try #require(await executor.insert(Transcript(typed: "one"), following: nil, since: .keyDown(.now)))
        let second = try #require(await executor.insert(Transcript(typed: " two"), following: first, since: .keyDown(.now)))
        _ = try await executor.insert(Transcript(typed: " three"), following: second, since: .keyUp(.now))

        #expect(inputMethod.destinations == [.cursorInFront, .app(Self.textEdit.rawValue), .app(Self.textEdit.rawValue)])
    }

    /// Nothing said is nothing inserted: the input method is never asked.
    @Test func aBlankTranscriptInsertsNothing() async throws {
        let inputMethod = Self.inserting(into: Self.textEdit)
        let executor = Executor(insertingThrough: inputMethod)
        for blank in [Transcript(words: []), Transcript(words: [.init(text: " ", time: 0...0, confidence: 1.0)])] {
            #expect(try await executor.insert(blank, following: nil, since: .keyUp(.now)) == nil)
        }
        #expect(inputMethod.texts.isEmpty)
    }

    /// Every refusal is thrown by its own name with nothing performed: the words are not at
    /// the cursor, and nothing puts them anywhere else. Over every case, so a refusal added
    /// later is covered by the compiler rather than by whoever remembers this file.
    @Test(arguments: Refusal.allCases)
    func aRefusalIsThrownByName(refusal: Refusal) async throws {
        let inputMethod = AnInputMethod { _ in throw refusal }
        let thrown = try await #require(throws: Refusal.self) {
            try await Executor(insertingThrough: inputMethod)
                .insert(Transcript(typed: "héllo there"), following: nil, since: .keyUp(.now))
        }

        #expect(thrown == refusal)
    }

    /// Words an app has not taken yet are thrown by that name, never as a refusal: they
    /// may still land, and nothing here sends them again.
    @Test func wordsNotYetTakenAreThrownByName() async throws {
        let late = NotYetTaken(characters: 11, into: "com.apple.TextEdit")
        let inputMethod = AnInputMethod { _ in throw late }
        let thrown = try await #require(throws: NotYetTaken.self) {
            try await Executor(insertingThrough: inputMethod)
                .insert(Transcript(typed: "héllo there"), following: nil, since: .keyUp(.now))
        }

        #expect(thrown == late)
    }

    /// Every way the channel fails is thrown the same way, by its own name.
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
    func aChannelThatFailsIsThrownByName(why: Unreachable) async throws {
        let inputMethod = AnInputMethod { _ in throw why }
        let thrown = try await #require(throws: Unreachable.self) {
            try await Executor(insertingThrough: inputMethod)
                .insert(Transcript(typed: "héllo there"), following: nil, since: .keyUp(.now))
        }

        #expect(thrown == why)
    }
}
