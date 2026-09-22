import AppKit
import Flavors
import InputMethod
import InputMethodKit

/// The input method process: macOS launches it out of its own bundle, it answers on its
/// flavor's connection, and it holds nothing else.
///
/// [LAW:effects-at-boundaries] Everything with an effect is here - reading the bundle,
/// opening the port, running the loop - so the controller beside it stays a pure answer to
/// a key.

/// [LAW:parse-dont-validate] The identifier macOS launched this process under is the only
/// thing it is told, and it already says which installation it belongs to. Nothing is
/// guessed from it: a bundle whose identifier is neither flavor's is a misbuilt bundle, and
/// serving the other copy's connection would put one installation's words in the other's
/// window. [LAW:no-silent-failure]
guard let identifier = Bundle.main.bundleIdentifier,
      let flavor = Flavor(inputMethodBundleIdentifier: identifier)
else {
    FileHandle.standardError.write(Data("""
        lowtalker-inputmethod: this bundle's identifier is \(Bundle.main.bundleIdentifier.map { "\($0.debugDescription)" } ?? "absent"), \
        which is no installation's input method; expected one of \
        \(Flavor.allCases.map(\.inputMethodBundleIdentifier).joined(separator: ", "))

        """.utf8))
    exit(1)
}

/// The server owns the port macOS reaches this process on. Held for the life of the process
/// by being a top-level binding: released, the connection goes with it and the text input
/// system's calls land nowhere.
guard let server = IMKServer(name: flavor.inputMethodConnectionName, bundleIdentifier: identifier) else {
    FileHandle.standardError.write(Data("""
        lowtalker-inputmethod: no server could be opened on \(flavor.inputMethodConnectionName)

        """.utf8))
    exit(1)
}

NSLog("lowtalker-inputmethod: %@ serving %@", flavor.description, server.bundle()?.bundleIdentifier ?? identifier)
NSApplication.shared.run()
