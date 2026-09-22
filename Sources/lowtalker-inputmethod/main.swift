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

/// The app's door, beside the text input system's. Held for the life of the process for
/// the same reason the server is: released, the app's next request finds nothing listening.
///
/// Hosted on this thread, which is the main one, so its answers run where `FocusedClient`
/// and every `IMKInputController` callback already run and the two never race.
/// [LAW:no-ambient-temporal-coupling] `assumeIsolated` is that sentence made checkable: if
/// this ever answered anywhere else it would stop here rather than corrupt a client.
///
/// An input method that cannot open this port still types nothing, so it ends the same way
/// a missing server does rather than running on as a source that answers no insert.
/// [LAW:no-silent-failure]
let insertions: InsertionPort = {
    do {
        return try InsertionPort(flavor: flavor) { text in
            MainActor.assumeIsolated {
                // Read here, where the effects are, and handed to the decision as a value.
                // [LAW:effects-at-boundaries]
                let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                let focused = FocusedClient.shared
                let answer = focused.insert(text, whileInFrontIs: frontmost)
                // Both apps by name, because the refusal that matters here is the one where
                // they differ, and a line naming only the outcome leaves a reader with the
                // question the line was written to answer.
                logger.notice("""
                    insert of \(text.count, privacy: .public) characters: \
                    \(String(describing: answer), privacy: .public); \
                    the cursor is in \(focused.application ?? "nothing", privacy: .public) \
                    and \(frontmost ?? "nothing", privacy: .public) is in front
                    """)
                return answer
            }
        }
    } catch {
        logger.fault("will not start: \(String(describing: error), privacy: .public)")
        exit(1)
    }
}()

logger.notice("""
    \(flavor.description, privacy: .public) serving \(flavor.inputMethodConnectionName, privacy: .public) \
    and answering inserts on \(flavor.inputMethodPortName, privacy: .public)
    """)
NSApplication.shared.run()
