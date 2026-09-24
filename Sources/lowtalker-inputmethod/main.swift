import AppKit
import Flavors
import InputMethod
import InputMethodKit
import Insertion
import os

/// The input method process: macOS launches it out of its own bundle, it answers on its
/// flavor's connection, and it holds nothing else.
///
/// [LAW:effects-at-boundaries] Everything with an effect is here - reading the bundle,
/// opening the port, running the loop - so the controller beside it stays a pure answer to
/// a key.
///
/// Said where `log show` will find it, the way the helper says it, and for the same reason:
/// LaunchServices launches this process with nowhere for standard error to go, so its only
/// voice is the unified log. Public on purpose - a redacted reason is no reason, and
/// measured, NSLog arrives there as `<private>` and says nothing at all.
///
///     log show --last 10m --predicate 'subsystem BEGINSWITH "ai.promptctl.low-talker"'

/// [LAW:parse-dont-validate] The identifier macOS launched this process under is the only
/// thing it is told, and it already says which installation it belongs to. Nothing is
/// guessed from it: a bundle whose identifier is neither flavor's is a misbuilt bundle, and
/// serving the other copy's connection would put one installation's words in the other's
/// window. [LAW:no-silent-failure]
///
/// The refusal is filed under every flavor's name, because which one this would have been
/// is exactly what is not known - so a reader who asks under either finds it.
let flavor: Flavor = {
    let identifier = Bundle.main.bundleIdentifier
    guard let identifier, let flavor = Flavor(inputMethodBundleIdentifier: identifier) else {
        for candidate in Flavor.allCases {
            Logger(subsystem: candidate.inputMethodBundleIdentifier, category: "inputmethod").fault(
                """
                will not start: this bundle's identifier is \(identifier ?? "absent", privacy: .public), \
                which is no installation's input method; expected one of \
                \(Flavor.allCases.map(\.inputMethodBundleIdentifier).joined(separator: ", "), privacy: .public)
                """)
        }
        exit(1)
    }
    return flavor
}()

private let logger = Logger(subsystem: flavor.inputMethodBundleIdentifier, category: "inputmethod")

/// The server owns the port macOS reaches this process on. Held for the life of the process
/// by being a top-level binding: released, the connection goes with it and the text input
/// system's calls land nowhere.
///
/// An input method that cannot open its port is one the Input menu still offers and that
/// does nothing when chosen, so it ends here rather than running on as a source that
/// silently never answers. [LAW:no-silent-failure]
let server: IMKServer = {
    guard let server = IMKServer(name: flavor.inputMethodConnectionName, bundleIdentifier: flavor.inputMethodBundleIdentifier) else {
        logger.fault("will not start: no server could be opened on \(flavor.inputMethodConnectionName, privacy: .public)")
        exit(1)
    }
    return server
}()

/// The app holding Secure Event Input, by name, or nil when nobody holds it.
///
/// Read from the window server's session, which names the holder's process rather than only
/// saying that someone holds it - the name is what the log line needs, since the fix is in
/// that app's own menu. A holder whose process has no name is still a holder, and is named
/// by its pid rather than read as none. [LAW:no-silent-failure]
@MainActor
func secureInputHolder() -> String? {
    // A session that cannot be read says nothing about secure input, which is not the same
    // as saying nobody holds it: said by name, and the insert goes ahead, since the client's
    // own answer is still the account of whether the words landed. [LAW:no-silent-failure]
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
        logger.error("the window server's session could not be read, so whether an app holds secure keyboard entry is unknown")
        return nil
    }
    guard let pid = session["kCGSSessionSecureInputPID"] as? pid_t, pid != 0 else { return nil }
    return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "process \(pid)"
}

/// The app's door, beside the text input system's. Held for the life of the process for
/// the same reason the server is: released, the app's next request finds nothing listening.
///
/// Answered on a queue of its own and never on the main one, which is where every key this
/// source passes through is handled. An insert asks the main actor only which cursor is in
/// front - where `FocusedClient` and every `IMKInputController` callback already run, so
/// the two never race - and then hands the words to the `Committer`, off the main thread.
/// Both waits are bounded by the committer, so a hung app costs the person an insert
/// answered by name and not a dead keyboard. [LAW:no-ambient-temporal-coupling]
/// `assumeIsolated` inside the ask is that sentence made checkable.
///
/// Only this installation's app gets through; every other sender is refused by the port
/// before its words are read, and the refusal is logged here with what was required.
///
/// A door that will not open is not the end of this process, unlike the server above it.
/// The controller's whole promise is that every key passes through untouched, so a person
/// with this source selected keeps a working keyboard even when nothing here can insert.
/// The fault names the `InsertionPort.NotHosted` case that stopped it - most often the name
/// already held by another instance of this input method, whose own cursor then answers the
/// app. [LAW:no-silent-failure]
let committer = Committer(label: "\(flavor.inputMethodPortName).commits")
let insertions: InsertionPort? = {
    do {
        return try InsertionPort(flavor: flavor, queue: DispatchQueue(label: flavor.inputMethodPortName), told: { event in
            logger.error("\(String(describing: event), privacy: .public)")
        }) { text in
            // Read on the main actor, where the effects are, and handed to the decision as
            // values. [LAW:effects-at-boundaries] Asked within the committer's bound, like
            // the commit, so the whole answer is one this process keeps.
            let seen = committer.ask(on: .main) {
                MainActor.assumeIsolated {
                    let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    let securing = secureInputHolder()
                    return (frontmost: frontmost, securing: securing, cursor: FocusedClient.shared.cursor(whileInFrontIs: frontmost, secureInputIsOn: securing != nil))
                }
            }
            let answer = committer.answer(text, at: seen?.cursor)
            // The app in front is named because the refusal that matters here is the one
            // where it is not the app holding the cursor, and a line saying only the outcome
            // leaves a reader with the question it was written to answer. A main thread that
            // did not look is said as not knowing, never as nothing in front.
            // [LAW:no-silent-failure]
            let context = seen.map { seen in
                "with \(seen.frontmost ?? "nothing") in front" + (seen.securing.map { ", secure input held by \($0)" } ?? "")
            } ?? "without knowing what is in front, since the main thread did not look in time"
            logger.notice("""
                insert of \(text.count, privacy: .public) characters: \
                \(String(describing: answer), privacy: .public), \(context, privacy: .public)
                """)
            return answer
        }
    } catch {
        logger.fault("""
            no insert port on \(flavor.inputMethodPortName, privacy: .public): \
            \(String(describing: error), privacy: .public); keys still pass through
            """)
        return nil
    }
}()

/// A cursor outlives its app unless someone says otherwise, and the text input system does
/// not always say. This is where the workspace is watched for it. [LAW:effects-at-boundaries]
/// Held for the life of the process, like everything else opened here.
let quits = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
) { note in
    let quit = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    MainActor.assumeIsolated { quit.map(FocusedClient.shared.applicationQuit) }
}

// What this process opened, rather than what it set out to open: the startup line is where
// a reader looks first, and one that named the insert port whether or not it exists would
// send them looking for a fault that is already in the log above. [LAW:no-silent-failure]
let inserts = insertions.map { _ in "answering inserts on \(flavor.inputMethodPortName)" } ?? "answering no inserts"
logger.notice("""
    \(flavor.description, privacy: .public) serving \(flavor.inputMethodConnectionName, privacy: .public), \
    \(inserts, privacy: .public)
    """)
NSApplication.shared.run()
