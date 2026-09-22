import Foundation
import InputMethodKit
import Insertion

/// Somewhere words can be put: what this process actually needs of the thing in front of
/// it, which is one thing out of the three dozen `IMKTextInput` offers.
///
/// [LAW:composability] Named here rather than passing the text input system's own protocol
/// around, because a type that demanded all of `IMKTextInput` could only ever be handed the
/// real one - by macOS, in a process macOS launched, with a person's cursor at the far end.
/// Everything below this line is then reachable without any of that.
@MainActor
public protocol TextCursor: AnyObject {
    /// The app this cursor belongs to, which is how a cursor left over from an app the
    /// person has since switched away from is told from the one in front of them.
    ///
    /// A cursor has one, always. It is read when the cursor is made, while the client is
    /// certainly alive, and never again: [FRAMING:representation] asking a client for its
    /// bundle identifier later means asking a proxy whose process may since have quit, and
    /// on the one path that must stay answerable - deciding whether to refuse - that is the
    /// last thing to reach for. A client that will not name one is no cursor at all, which
    /// its constructor establishes rather than leaving every reader of this to ask again.
    /// [LAW:parse-dont-validate]
    var application: String { get }
    /// Commits `text` at the insertion point, taking nothing away.
    func commit(_ text: String)
}

/// The client the text input system has given focus to, and the one thing in this process
/// that can commit text into it.
///
/// [LAW:no-shared-mutable-globals] One owner with an explicit API, and shared because it
/// has to be: `IMKServer` builds a controller per client out of the class name in the
/// bundle's `Info.plist`, so there is no constructor of ours to hand anything to. Every
/// controller reports focus here, and the insert port asks here; those are the only two
/// doors, and both are on the main actor.
///
/// Its whole state is which cursor is in front, which is a fact macOS owns and this only
/// mirrors. [FRAMING:representation] Nothing is remembered about text already inserted -
/// the client is the document, and a second copy of what it holds could only disagree.
@MainActor
public final class FocusedClient {
    public static let shared = FocusedClient()

    /// The cursor in front, which carries the app it belongs to.
    private var focus: (any TextCursor)?

    /// Whether this process currently has somewhere to put words. What
    /// low-input-method-s71.48t's readiness row will read.
    public var hasFocus: Bool { focus != nil }

    /// The text input system gave this cursor focus.
    ///
    /// Unconditional, because there is no half-cursor left for it to sort out: a client that
    /// will not name its app is refused by `Client.init`, so the rule lives at the one place
    /// a cursor comes into being rather than at every place one is handled.
    /// [LAW:parse-dont-validate] [LAW:single-enforcer]
    public func took(_ cursor: any TextCursor) { focus = cursor }

    /// The text input system took focus away from this cursor.
    public func left(_ leaving: any TextCursor) {
        // Not unconditional: focus can move by activating the new client before
        // deactivating the old, and clearing on the old one's word would then drop the
        // client that just arrived and refuse the next insert for no reason.
        focus = focus === leaving ? nil : focus
    }

    /// An app quit. Any cursor of its is gone with it, whatever the text input system did
    /// or did not say about it.
    ///
    /// The case this closes, which no comparison against the app in front can: the person
    /// dictates into TextEdit, quits it, and launches it again. TextEdit is in front, its
    /// new client has not reported focus yet, and the cursor still held is a proxy for a
    /// process that no longer exists - so the app names match, the commit goes nowhere, and
    /// the answer claims it landed. Killing the cursor when the app dies is the only moment
    /// at which that is knowable. [LAW:no-silent-failure]
    ///
    /// By name and not by process, because a process is not something the text input system
    /// hands over: it gives this one a client. So the other ordering is possible - a
    /// termination notice delayed past a relaunched app taking focus clears a cursor that is
    /// live - and it is the direction chosen, because a refusal is seen and answered while a
    /// commit into a proxy for a dead process is answered `inserted` and vanishes.
    public func applicationQuit(_ application: String) {
        focus = focus?.application == application ? nil : focus
    }

    /// Commits `text` at the cursor in front, replacing nothing, provided the cursor is in
    /// the app that is actually in front.
    ///
    /// Absence is not a mistake to guard against but the answer itself: nowhere to put
    /// words is exactly the case low-input-method-s71.b26 puts on the clipboard instead.
    ///
    /// **What `inserted` claims, exactly: the client belonging to the app in front accepted
    /// the commit.** Not that a person saw the words. The text input system offers no
    /// delivery report, and measured on 2026-09-22 there is nothing to derive one from: the
    /// Finder's desktop presents a full text client that accepts `insertText` into a buffer
    /// nobody can see and grows its own `length()` doing it, while iTerm2 - where the words
    /// land in plain sight - answers `length()` of 0 before and after. A check for "did the
    /// document grow" would pass the desktop and refuse the terminal. So no such check is
    /// made up here, and what the answer says is what was actually established.
    /// [LAW:no-silent-failure] The rest belongs to low-input-method-s71.31s's notes.
    ///
    /// The app in front is compared rather than assumed, which is the part that IS
    /// establishable: focus can move to an app that never becomes a client at all, and then
    /// nothing deactivates the cursor left standing. That case was not reproduced on this
    /// Mac - every app tried presented a client - so this is held by the suite and not by a
    /// reading, and it is here because committing into a window the person has left is the
    /// one outcome worse than refusing.
    ///
    /// Which app is in front arrives as a value rather than being read here, so the whole
    /// of this decision is testable without a window server and the one reading of the
    /// workspace happens where the other effects are. [LAW:effects-at-boundaries]
    public func insert(_ text: String, whileInFrontIs frontmost: String?) -> InsertionAnswer {
        guard let focus else { return .refused(.noClientHasFocus) }
        guard focus.application == frontmost else { return .refused(.cursorIsInAnotherApp) }
        focus.commit(text)
        return .inserted(characters: text.count)
    }
}

/// The text input system's client, as the one thing this process asks of it.
///
/// `NSNotFound` as the replacement range is how the text input system is told "at the
/// insertion point, and do not take anything away" - the same commit a Japanese or Chinese
/// input method performs when the user accepts a candidate, which is why this reaches
/// terminals, browsers and Electron apps that no synthesised keystroke would.
@MainActor
final class Client: TextCursor {
    private let client: IMKTextInput
    let application: String

    /// Nothing at all when the client will not name its app. [LAW:parse-dont-validate] The
    /// one place the question is asked, and past it there is a cursor whose app is known
    /// rather than one every later reader has to keep asking about - which is also what
    /// makes `activateServer` able to keep the cursor it last reported: a cursor that exists
    /// is one `FocusedClient` will take.
    init?(_ client: IMKTextInput) {
        guard let application = client.bundleIdentifier() else { return nil }
        self.client = client
        self.application = application
    }

    func commit(_ text: String) {
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}
