import Foundation
@testable import InputMethod
import Insertion
import Testing

/// Committing, and how long an answer waits for it.
///
/// [LAW:behavior-not-structure] Held through `TextCursor`, with a cursor that can be made
/// to hang the way an app whose main thread is asleep does. A bound only the stuck case
/// tests is small; every case that expects a commit to finish gives it a bound no runner
/// stall can spend, because a busy CI machine is not a hung app.
@Suite struct CommitterTests {
    /// A cursor in some app, which records what it was given and, when told to, holds each
    /// commit until the test lets it go.
    private final class Cursor: TextCursor, @unchecked Sendable {
        let application = "com.example.editor"
        private let lock = NSLock()
        private var landed: [String] = []
        private var onMain: [Bool] = []
        private let held: DispatchSemaphore?

        init(holding: Bool = false) { held = holding ? DispatchSemaphore(value: 0) : nil }

        func commit(_ text: String) {
            held?.wait()
            lock.withLock {
                landed.append(text)
                onMain.append(Thread.isMainThread)
            }
        }

        func release() { held?.signal() }
        var committed: [String] { lock.withLock { landed } }
        var committedOnMain: [Bool] { lock.withLock { onMain } }
    }

    private static let unspendable = Duration.seconds(20)

    @Test func wordsCommittedAreAnsweredWithTheirCount() {
        let cursor = Cursor()
        let answer = Committer(bound: Self.unspendable, label: #function).commit("🫠 hello", at: cursor)

        // The count is what a person would count, not what a buffer would: an emoji is one
        // character to whoever dictated it.
        #expect(answer == .inserted(characters: 7, into: cursor.application))
        #expect(cursor.committed == ["🫠 hello"])
    }

    /// Asked from the main thread, committed off it: a commit made on the main thread is the
    /// one a hung app turns into a dead keyboard.
    @MainActor
    @Test func aCommitAskedOnTheMainThreadIsNotMadeThere() {
        let cursor = Cursor()
        _ = Committer(bound: Self.unspendable, label: #function).commit("hello", at: cursor)

        #expect(cursor.committedOnMain == [false])
    }

    @Test func wordsAskedForInOrderLandInOrder() {
        let cursor = Cursor()
        let committer = Committer(bound: Self.unspendable, label: #function)
        for word in ["one", "two", "three"] { _ = committer.commit(word, at: cursor) }

        #expect(cursor.committed == ["one", "two", "three"])
    }

    /// An app that does not take the words in time is refused by name - and the words are
    /// not lost with it, nor committed twice: they land when the app comes back, once
    /// each, in the order they were asked for. Every answer here is given while the cursor
    /// is still held, so no runner stall can turn one into the other.
    @Test func commitsThatDoNotFinishAreRefusedByNameAndStillLandOnceInOrder() {
        let hung = Cursor(holding: true)
        let committer = Committer(bound: .milliseconds(50), label: #function)

        #expect(committer.commit("first", at: hung) == .refused(.clientIsNotAnswering))
        #expect(committer.commit("second", at: hung) == .refused(.clientIsNotAnswering))
        #expect(hung.committed.isEmpty)

        hung.release()
        hung.release()
        let deadline = ContinuousClock.now + Self.unspendable
        while hung.committed.count < 2, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(hung.committed == ["first", "second"])
    }

    /// The input method's answer naming a hung app has to reach the app before the app
    /// stops listening, which it does after one of its four phases.
    @Test func theBoundIsWithinOnePhaseOfTheAppsWait() {
        #expect(Committer.standardBound < InputMethodInserter.standardTimeout / 4)
    }
}
