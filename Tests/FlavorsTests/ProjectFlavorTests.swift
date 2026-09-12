import Flavors
import Foundation
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// project.yml builds one app bundle per flavor, under that flavor's own names.
///
/// xcodegen cannot read a Swift constant, so the bundle identifier, the product name and
/// the launchd plist are written again in project.yml, and this is what keeps those copies
/// from drifting. [LAW:one-source-of-truth] The failure they would otherwise cause is
/// silent in the worst way: two bundles that agree on an identifier are one installation
/// as far as LaunchServices, TCC and Login Items are concerned, so the second copy would
/// install over the first's grants rather than beside them - and nothing would say so
/// until a hotkey went to the wrong app.
///
/// [LAW:behavior-not-structure] Driven from `Flavor.allCases`, so a flavor added without a
/// target fails here rather than at whatever later moment somebody tries to build it.
@Suite struct ProjectFlavorTests {
    /// Every `templateAttributes:` block in project.yml, as the names it sets.
    ///
    /// Read as blocks rather than as lines anywhere in the file, because that is the whole
    /// question: three names that belong to one installation must be set on one target.
    /// A `contains` over the file would pass on a project.yml that gave the release bundle
    /// the development plist.
    private static func installations() throws -> [[String: String]] {
        let yaml = try String(contentsOf: repository.appending(path: "project.yml"), encoding: .utf8)
        return yaml.components(separatedBy: "templateAttributes:\n").dropFirst().map { block in
            var names: [String: String] = [:]
            for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                let name = line.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix(" "), let colon = name.firstIndex(of: ":") else { break }
                names[String(name[name.startIndex..<colon])] =
                    String(name[name.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            return names
        }
    }

    @Test(arguments: Flavor.allCases)
    func theProjectBuildsABundleUnderEveryFlavorsOwnNames(flavor: Flavor) throws {
        let installations = try Self.installations()
        let mine = try #require(
            installations.first { $0["bundleIdentifier"] == flavor.bundleIdentifier },
            "project.yml builds nothing under \(flavor.bundleIdentifier); it builds \(installations)"
        )
        #expect(mine["displayName"] == flavor.displayName)
        #expect(mine["launchdLabel"] == flavor.launchdLabel)
    }

    /// The count as well as the contents, so a third target copied from one of these -
    /// carrying whichever names its author forgot to change - is not silently tolerated by
    /// a check that only ever looks for flavors it already knows.
    @Test func theProjectBuildsNothingThatIsNotAFlavor() throws {
        let installations = try Self.installations()
        #expect(installations.count == Flavor.allCases.count, "project.yml builds \(installations)")
    }
}
