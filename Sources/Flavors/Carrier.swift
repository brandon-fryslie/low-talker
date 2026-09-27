import Foundation

/// Where an installation's executables sit in relation to one another.
///
/// Each app carries the programs it runs - itself, its keyboard helper and its copy of the
/// CLI - and every one of them can find the others from its own path. A build from a
/// checkout carries nothing and puts them side by side in one directory. Those two layouts
/// are the whole of it, and they are written here once. [LAW:one-source-of-truth]
public enum Carrier {
    /// The nearest `.app` enclosing an executable, or nil for one no bundle holds.
    ///
    /// Links are resolved first. A CLI reached through a link on PATH - the way a person
    /// without a checkout is told to reach it - otherwise sees no bundle at all. Measured:
    /// a tool inside `X.app/Contents` reads X.app's identifier when run in place and nil
    /// when run through a symlink.
    public static func app(enclosing executable: URL) -> URL? {
        sequence(first: executable.resolvingSymlinksInPath()) { url in
            url.pathComponents.count > 1 ? url.deletingLastPathComponent() : nil
        }.first { $0.pathExtension == "app" }
    }

    /// Where an app bundle keeps its keyboard helper: the `BundleProgram` its own launchd
    /// plist names, which `HelperPlistTests` holds this to.
    public static let helperInBundle = "Contents/MacOS/lowtalker-keyboardd"

    /// Where an app bundle keeps the lowtalker CLI, which onboarding names to a person who
    /// installed only the app: project.yml's `lowtalker-cli` embed, which `CarriedCLITests`
    /// holds this to, since xcodegen cannot read Swift.
    public static let cliInBundle = "Contents/Helpers/lowtalker"

    /// The CLI inside `bundle`.
    public static func cli(in bundle: URL) -> String { bundle.appending(path: cliInBundle).path }

    /// The keyboard helper that shipped with this executable: the one in the enclosing
    /// app, or the one built beside it.
    public static func keyboardHelper(shippedWith executable: URL) -> URL {
        app(enclosing: executable).map { $0.appending(path: helperInBundle) }
            ?? executable.resolvingSymlinksInPath().deletingLastPathComponent().appending(path: "lowtalker-keyboardd")
    }
}
