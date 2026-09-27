import Foundation

/// Where an installation's executables sit in relation to one another.
///
/// Each app carries the programs it runs - itself and its copy of the CLI - and each can find
/// the other from its own path. A build from a checkout carries nothing. Those two layouts
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

    /// The installation an executable belongs to: the flavor its enclosing app's identifier
    /// names, development for one no bundle holds - a build from a checkout is the
    /// development copy - and nil inside a bundle that is no installation's.
    public static func installation(of executable: URL) -> Flavor? {
        guard let app = app(enclosing: executable) else { return .development }
        return Bundle(url: app)?.bundleIdentifier.flatMap(Flavor.init(bundleIdentifier:))
    }

    /// Where an app bundle keeps the lowtalker CLI, which the app reads its grants through:
    /// project.yml's `lowtalker-cli` embed, which `CarriedCLITests` holds this to, since
    /// xcodegen cannot read Swift.
    public static let cliInBundle = "Contents/Helpers/lowtalker"

    /// The CLI inside `bundle`.
    public static func cli(in bundle: URL) -> String { bundle.appending(path: cliInBundle).path }
}
