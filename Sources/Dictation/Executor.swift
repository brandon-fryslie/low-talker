import Foundation
import Insertion
import LowTalkerCore
import os

/// Performs a route's actions: text at the focus asked of the input method, which commits it
/// at the cursor through the text input system - no key posted, no pasteboard touched, and no
/// grant asked of an administrator.
///
/// [LAW:effects-at-boundaries] The router hands back descriptions; this is the edge where they
/// become inserts. The inserter is a value it is given - the input method's port in the app, a
/// fake in a test - so the executor itself decides only what each action is and how much of
/// the list was done.
///
/// Every action is proven before any is performed. An action list is a whole the same way a
/// string is: a list that inserted its first action and refused its second would leave half
/// a route in the document, and the half is not marked as half. [LAW:parse-dont-validate]
@MainActor
public struct Executor {
    private let inserter: any Inserter
    private let log: Logger

    /// Words that do not reach the cursor are a failure and are thrown as one: the input
    /// method's refusal or the channel's, by name. Nothing puts them anywhere else.
    /// [LAW:no-silent-failure]
    public init(insertingThrough inserter: any Inserter, log: Logger = Executor.log) {
        self.inserter = inserter
        self.log = log
    }

    nonisolated public static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "lowtalker", category: "insert")

    /// The key event an insert is timed from: key-down for words committed while the press is
    /// still open, key-up for what is inserted once it is over.
    public struct Since: Sendable {
        public enum Key: String, Sendable {
            case down = "key-down"
            case up = "key-up"
        }

        public let key: Key
        public let instant: ContinuousClock.Instant

        public static func keyDown(_ instant: ContinuousClock.Instant) -> Since { Since(key: .down, instant: instant) }
        public static func keyUp(_ instant: ContinuousClock.Instant) -> Since { Since(key: .up, instant: instant) }
    }

    /// One insert, done. The time is from the key event it is timed from to the input
    /// method's answer.
    public struct Performed: CustomStringConvertible, Sendable {
        public let characters: Int
        /// The app whose cursor took the words, as the input method names it - not
        /// necessarily the one in front at key-down: the person can move between the chord
        /// and the dictation's first words being ready, and those go where the cursor is then.
        /// [FRAMING:representation]
        public let into: BundleID
        public let acknowledged: Duration
        public let since: Since.Key

        public var description: String {
            "inserted \(characters) characters at the cursor in \(into.rawValue), \(since.rawValue) to acknowledged \(Int(acknowledged / .milliseconds(1))) ms"
        }
    }

    /// Performs every action in order, each logged as it completes, and answers with what was
    /// done. Throws `NotAnInsert` before the first insert when any action is not text at the
    /// focus; throws `RouteStopped` from the insert that stopped, carrying the earlier ones,
    /// which are done.
    ///
    /// `earlier` is what the same dictation already inserted. Each insert goes only to the
    /// app the one before it went to, so a dictation's words all land in one app, and the
    /// first goes to the cursor in front. [LAW:one-source-of-truth] Derived here from what
    /// landed, the one record of where that was.
    @discardableResult
    public func perform(_ actions: [Action], following earlier: [Performed], since: Since) async throws -> [Performed] {
        let texts = try actions.map(Self.text(of:))
        let clock = ContinuousClock()
        var performed: [Performed] = []
        for text in texts {
            let destination = (earlier + performed).last.map { Destination.app($0.into.rawValue) } ?? .cursorInFront
            // Awaited, so the round trip runs on a thread of its own: this is the main actor,
            // and `Inserter` says in its own contract that the blocking call must not pump it.
            // [LAW:no-ambient-temporal-coupling] A refusal or a channel failure is thrown on
            // as it is, and stops the route by name.
            let inserted: Inserted
            do { inserted = try await inserter.insert(text, into: destination) } catch { throw RouteStopped(performed: performed, cause: error) }
            let done = Performed(characters: inserted.characters, into: BundleID(rawValue: inserted.into), acknowledged: clock.now - since.instant, since: since.key)
            log.info("\(done.description, privacy: .public)")
            performed.append(done)
        }
        return performed
    }

    /// [LAW:parse-dont-validate] The one place an action becomes something the input method
    /// can do.
    private static func text(of action: Action) throws -> String {
        switch action {
        case .insertText(let text): text
        case .activateApp, .openURL, .runShortcut, .pipe: throw NotAnInsert(action: action)
        }
    }
}

/// A list that stopped part way: the insert that stopped is the cause, and the ones before it
/// are done and cannot be taken back, so they travel with it. Text is in the document either
/// way; what this adds is which of it, so a retry does not insert it twice.
public struct RouteStopped: StoppedPartWay, CustomStringConvertible {
    public let performed: [Executor.Performed]
    public let cause: any Error

    public init(performed: [Executor.Performed], cause: any Error) {
        self.performed = performed
        self.cause = cause
    }

    public var description: String {
        let before = performed.isEmpty ? "" : " Performed before it: " + performed.map(\.description).joined(separator: "; ") + "."
        return "\(cause)\(before)"
    }
}

/// An action that is not text at the cursor, which is the one thing the input method puts
/// anywhere. [LAW:no-silent-failure] Refused by name, so a route is never half-performed
/// without a word.
public struct NotAnInsert: Error, CustomStringConvertible {
    public let action: Action

    public var description: String { "WARNING: \(action) is not text at the cursor, and text at the cursor is all the input method puts anywhere. Nothing was done." }
}
