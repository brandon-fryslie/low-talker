import Foundation

/// Where an app bundle carries the lowtalker CLI, which is what onboarding names to a
/// person who installed only the app.
///
/// [LAW:one-source-of-truth] project.yml's `lowtalker-cli` embed decides this; xcodegen
/// cannot read Swift, so it is written again here, and `CarriedCLITests` holds the two
/// equal. The CLI itself never needs it: it finds its carrier by walking up to the
/// nearest `.app`.
public enum CarriedCLI {
    /// The CLI's path inside a bundle, from the bundle's root.
    public static let pathInBundle = "Contents/Helpers/lowtalker"

    /// The CLI inside `bundle`.
    public static func path(in bundle: URL) -> String { bundle.appending(path: pathInBundle).path }
}
