@testable import InputMethod
import Insertion
import Testing

/// Where the words go, and what is answered when there is nowhere.
///
/// [LAW:behavior-not-structure] Asked through `TextCursor`, which is the whole of what this
/// process needs of the thing in front of it. The text input system's own client is
/// `IMKTextInput` and cannot be stood in for - three dozen members, all of them macOS's -
/// so a type that demanded it could only ever be exercised by a person at a keyboard. That
/// the seam is narrow enough to test is the same fact as its being narrow enough to reason
/// about.
///
/// Each case builds its own `FocusedClient` rather than moving focus on the shared one:
/// that one belongs to the process macOS launched, and cases sharing it would be moving
/// each other's focus.
@MainActor
@Suite struct FocusedClientTests {
    /// A place words can land, which remembers what landed and which app it is in.
    private final class Cursor: TextCursor {
        let application: String?
        private(set) var committed: [String] = []

        init(in application: String? = "com.example.editor") { self.application = application }

        func commit(_ text: String) { committed.append(text) }
    }

    /// The app in front, for the cases where it is simply whoever holds the cursor.
    private static let inFront = "com.example.editor"

    @Test func wordsLandAtTheCursorInFront() {
        let client = FocusedClient()
        let cursor = Cursor()
        client.took(cursor)

        #expect(client.insert("hello there", whileInFrontIs: Self.inFront) == .inserted(characters: 11))
        #expect(cursor.committed == ["hello there"])
    }

    /// The count is what a person would count, not what a buffer would: an emoji is one
    /// character to whoever dictated it.
    @Test func theCountIsOfCharactersAndNotOfBytes() {
        let client = FocusedClient()
        client.took(Cursor())

        #expect(client.insert("🫠", whileInFrontIs: Self.inFront) == .inserted(characters: 1))
    }

    /// Nothing in front is an answer, not a failure - it is the case
    /// low-input-method-s71.b26 puts on the clipboard instead.
    @Test func nothingInFrontIsRefusedByName() {
        #expect(FocusedClient().insert("hello", whileInFrontIs: Self.inFront) == .refused(.noClientHasFocus))
        #expect(FocusedClient().hasFocus == false)
    }

    /// A cursor that will not name its app is not focus, and does not become it. One
    /// controller failing to understand its sender must not speak for the others.
    @Test func aCursorThatNamesNoAppNeverTakesFocus() {
        let client = FocusedClient()
        let nameless = Cursor(in: nil)
        client.took(nameless)

        #expect(client.hasFocus == false)
        #expect(client.insert("hello", whileInFrontIs: Self.inFront) == .refused(.noClientHasFocus))
        #expect(nameless.committed.isEmpty)
    }

    /// And it does not take focus AWAY from a cursor that has it, which is the half that
    /// would otherwise refuse an insert with a live cursor sitting right there.
    @Test func aCursorThatNamesNoAppDoesNotDisturbTheOneInFront() {
        let client = FocusedClient()
        let real = Cursor()
        client.took(real)
        client.took(Cursor(in: nil))

        #expect(client.hasFocus)
        #expect(client.insert("hello", whileInFrontIs: Self.inFront) == .inserted(characters: 5))
        #expect(real.committed == ["hello"])
    }

    /// A cursor does not outlive the app it belongs to. Without this the person could
    /// dictate into TextEdit, quit it, launch it again, and have the words answered
    /// `inserted` into a client whose process no longer exists - the app names would match
    /// and nothing else would object. [LAW:no-silent-failure]
    @Test func aCursorDiesWithItsApp() {
        let client = FocusedClient()
        let cursor = Cursor(in: "com.apple.TextEdit")
        client.took(cursor)
        client.applicationQuit("com.apple.TextEdit")

        #expect(client.hasFocus == false)
        #expect(client.insert("hello", whileInFrontIs: "com.apple.TextEdit") == .refused(.noClientHasFocus))
        #expect(cursor.committed.isEmpty)
    }

    /// Some other app quitting is not this cursor's business.
    @Test func anotherAppQuittingLeavesTheCursorAlone() {
        let client = FocusedClient()
        let cursor = Cursor()
        client.took(cursor)
        client.applicationQuit("com.apple.Safari")

        #expect(client.hasFocus)
        #expect(client.insert("hello", whileInFrontIs: Self.inFront) == .inserted(characters: 5))
    }

    @Test func aCursorThatLeavesTakesTheFocusWithIt() {
        let client = FocusedClient()
        let cursor = Cursor()
        client.took(cursor)
        client.left(cursor)

        #expect(client.hasFocus == false)
        #expect(client.insert("hello", whileInFrontIs: Self.inFront) == .refused(.noClientHasFocus))
        #expect(cursor.committed.isEmpty)
    }

    /// Committing into a window the person has left is the one outcome worse than
    /// refusing, and it is reachable: focus can move to an app that never becomes a client
    /// of this input method, and then nothing deactivates the cursor left standing. Held
    /// here and not by a reading - on this Mac every app tried, the Finder's desktop
    /// included, presented a client of its own. [LAW:no-silent-failure]
    @Test func aCursorLeftBehindInAnotherAppIsRefusedRatherThanInsertedInto() {
        let client = FocusedClient()
        let cursor = Cursor(in: "com.apple.TextEdit")
        client.took(cursor)

        #expect(client.insert("hello", whileInFrontIs: "com.apple.finder") == .refused(.cursorIsInAnotherApp))
        #expect(cursor.committed.isEmpty)
    }

    /// The one that matters: focus can move by activating the new client before
    /// deactivating the old, and a `left` that cleared on anyone's word would drop the
    /// client that just arrived. The words would then go to the clipboard with a live
    /// cursor sitting right there, and nothing would say why. [LAW:no-silent-failure]
    @Test func aCursorLeavingAfterAnotherArrivedDoesNotTakeTheNewOnesFocus() {
        let client = FocusedClient()
        let old = Cursor()
        let new = Cursor()
        client.took(old)
        client.took(new)
        client.left(old)

        #expect(client.hasFocus)
        #expect(client.insert("hello", whileInFrontIs: Self.inFront) == .inserted(characters: 5))
        #expect(new.committed == ["hello"])
        #expect(old.committed.isEmpty)
    }
}
