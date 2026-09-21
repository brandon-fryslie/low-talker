import Flavors
import Foundation
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// project.yml builds one app bundle per flavor, under that flavor's own names.
///
/// xcodegen cannot read a Swift constant, so every name `Flavor` decides that a target
/// needs - the bundle identifier, the product name, the launchd plist, and the input
/// method's three - is written again in project.yml, and this is what keeps those copies
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
    /// question: the names that belong to one installation must be set on one target.
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

    /// Every name a flavor owns, which is how a block in project.yml is recognised as
    /// that flavor's. Exact strings, never prefixes: a development name contains its
    /// release name, so matching loosely would file both blocks under `release`.
    private static func names(of flavor: Flavor) -> Set<String> {
        [
            flavor.bundleIdentifier, flavor.displayName, flavor.launchdLabel,
            flavor.inputMethodBundleIdentifier, flavor.inputSourceIdentifier,
            flavor.inputMethodConnectionName,
        ]
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
        #expect(mine["inputMethodBundleIdentifier"] == flavor.inputMethodBundleIdentifier)
        #expect(mine["inputSourceIdentifier"] == flavor.inputSourceIdentifier)
        #expect(mine["inputMethodConnectionName"] == flavor.inputMethodConnectionName)
    }

    /// Counted per flavor rather than in total, so a third target copied from one of these
    /// - carrying whichever names its author forgot to change - still fails, while a
    /// second *kind* of target per flavor does not.
    ///
    /// The input method bundle (low-input-method-s71.0ae) is that second kind: it adds one
    /// block per flavor, and a flat `count == Flavor.allCases.count` would have failed on
    /// the arrival of a correct target. What has to hold is not how many blocks there are
    /// but that every one belongs to exactly one flavor and that no flavor has more of
    /// them than its sibling - which is the real question, since a stray target is exactly
    /// a flavor gaining a block the other did not. [LAW:behavior-not-structure]
    @Test func theProjectBuildsNothingThatIsNotAFlavor() throws {
        var blocksPerFlavor: [Flavor: Int] = [:]
        for block in try Self.installations() {
            let values = Set(block.values)
            let owners = Flavor.allCases.filter { !Self.names(of: $0).isDisjoint(with: values) }
            #expect(owners.count == 1, "a templateAttributes block names \(owners) rather than one flavor: \(block)")
            owners.first.map { blocksPerFlavor[$0, default: 0] += 1 }
        }
        #expect(blocksPerFlavor.count == Flavor.allCases.count, "a flavor has no target at all: \(blocksPerFlavor)")
        #expect(Set(blocksPerFlavor.values).count == 1, "the flavors have different numbers of targets: \(blocksPerFlavor)")
    }

    /// The helper signs under the name the release copy's helper serves: one namespace for
    /// the whole program. project.yml's helper target is where both builds of it read the
    /// identifier from, so it is the copy held to `Flavor` here.
    @Test func theHelperSignsUnderTheNameItServes() throws {
        let yaml = try String(contentsOf: repository.appending(path: "project.yml"), encoding: .utf8)
        let helper = try #require(yaml.components(separatedBy: "\n  lowtalker-keyboardd:\n").dropFirst().first, "project.yml has no lowtalker-keyboardd target")
        let identifiers = helper.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("PRODUCT_BUNDLE_IDENTIFIER:") }
        #expect(identifiers == ["PRODUCT_BUNDLE_IDENTIFIER: \(Flavor.release.machServiceName)"])
    }
}
