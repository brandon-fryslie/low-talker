import AppKit
import Flavors
import InputMethod
import InputMethodKit
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

logger.notice("\(flavor.description, privacy: .public) serving \(flavor.inputMethodConnectionName, privacy: .public)")
NSApplication.shared.run()
