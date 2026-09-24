import Foundation
import Insertion

/// Where commits run, and how long an answer waits for one.
///
/// Measured on low-input-method-s71.c7d against an app whose main thread was asleep:
/// - Made on the main thread, a commit waits for the app to answer, up to 3 s, and then
///   returns as if nothing were wrong. That wait holds every key this source passes
///   through, in every app, once per insert.
/// - Made off it, a commit hands the words to the app's queue and returns at once. The app
///   takes them when it recovers, in the order they were sent.
///
/// So commits run here, on a queue of their own. [LAW:no-ambient-temporal-coupling] It is
/// serial, so words asked for in order are committed in order. The caller still waits only
/// `bound`, because the call is macOS's and not this process's to trust: a commit that does
/// not return in time is answered by name rather than waited on.
///
/// **What `inserted` claims, exactly: the words were handed to the client of the app in
/// front.** Not that the app has taken them, and not that a person saw them. Off the main
/// thread even a read of the client returns at once from a hung app, so nothing here can
/// ask whether the app took the words. The text input system
/// offers no delivery report, and measured on 2026-09-22 there is nothing to derive one
/// from: the Finder's desktop presents a full text client that accepts `insertText` into a
/// buffer nobody can see and grows its own `length()` doing it, while iTerm2 - where the
/// words land in plain sight - answers `length()` of 0 before and after. A check for "did
/// the document grow" would pass the desktop and refuse the terminal. So no such check is
/// made up here, and what the answer says is what was actually established.
/// [LAW:no-silent-failure] The rest belongs to low-input-method-s71.31s's notes.
///
/// Past `bound` the answer is `clientIsNotAnswering`, and the commit is left to finish:
/// the words are already on their way to the app, and they land when it recovers. Nothing
/// is committed twice for it.
public final class Committer: Sendable {
    /// Beneath one phase of the app's own wait, so this answer arrives before the app
    /// stops listening. `CommitterTests` holds the two apart.
    public static let standardBound = Duration.milliseconds(500)

    private let bound: Duration
    private let queue: DispatchQueue

    public init(bound: Duration = standardBound, label: String) {
        self.bound = bound
        self.queue = DispatchQueue(label: label)
    }

    /// Commits `text` at `cursor`, answering once the app takes it or `bound` has passed.
    /// Blocks the caller for at most `bound`, so it belongs on a queue that is not the one
    /// keys are handled on.
    public func commit(_ text: String, at cursor: any TextCursor) -> InsertionAnswer {
        let taken = DispatchSemaphore(value: 0)
        queue.async {
            cursor.commit(text)
            taken.signal()
        }
        guard taken.wait(timeout: .now() + bound.timeInterval) == .success else { return .refused(.clientIsNotAnswering) }
        return .inserted(characters: text.count, into: cursor.application)
    }
}

extension Duration {
    /// Seconds, as Dispatch counts them.
    fileprivate var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
