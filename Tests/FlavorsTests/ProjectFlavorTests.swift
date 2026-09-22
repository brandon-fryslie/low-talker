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
    /// A target in project.yml: the name it is declared under, and the names it sets.
    private struct Target {
        let name: String
        let sets: [String: String]
    }

    /// Every `templateAttributes:` block in project.yml, as the target it belongs to.
    ///
    /// Read as blocks rather than as lines anywhere in the file, because that is the whole
    /// question: the names that belong to one installation must be set on one target.
    /// A `contains` over the file would pass on a project.yml that gave the release bundle
    /// the development plist.
    ///
    /// The target's own name is carried too, and it is not decoration: an app names the
    /// input method it embeds by TARGET name, so without it nothing can tell whether the
    /// target an app carries is the one building that flavor's input method. The name is the
    /// last two-space-indented `<name>:` line before the block - which is where xcodegen
    /// reads it from as well.
    private static func installations() throws -> [Target] {
        let yaml = try String(contentsOf: repository.appending(path: "project.yml"), encoding: .utf8)
        let chunks = yaml.components(separatedBy: "templateAttributes:\n")
        return chunks.dropFirst().enumerated().map { preceding, block in
            var sets: [String: String] = [:]
            for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                let name = line.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix(" "), let colon = name.firstIndex(of: ":") else { break }
                sets[String(name[name.startIndex..<colon])] =
                    String(name[name.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            let declaration = chunks[preceding].split(separator: "\n", omittingEmptySubsequences: false).last {
                $0.hasPrefix("  ") && !$0.hasPrefix("   ") && $0.hasSuffix(":") && !$0.contains("#")
            }
            return Target(name: declaration.map { String($0.trimmingCharacters(in: .whitespaces).dropLast()) } ?? "",
                          sets: sets)
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
            installations.first { $0.sets["bundleIdentifier"] == flavor.bundleIdentifier },
            "project.yml builds nothing under \(flavor.bundleIdentifier); it builds \(installations)"
        )
        #expect(mine.sets["displayName"] == flavor.displayName)
        #expect(mine.sets["launchdLabel"] == flavor.launchdLabel)
    }

    /// The input method bundle each app carries is built under its own flavor's names.
    ///
    /// They sit on this target and not on the app's, so the app carries only the name of
    /// the target it embeds; a block is found here by the identifier it builds, which is
    /// the same way the app's is found above.
    @Test(arguments: Flavor.allCases)
    func theProjectBuildsAnInputMethodUnderEveryFlavorsOwnNames(flavor: Flavor) throws {
        let installations = try Self.installations()
        let mine = try #require(
            installations.first { $0.sets["inputMethodBundleIdentifier"] == flavor.inputMethodBundleIdentifier },
            "project.yml builds no input method under \(flavor.inputMethodBundleIdentifier); it builds \(installations)"
        )
        #expect(mine.sets["displayName"] == flavor.displayName)
        #expect(mine.sets["inputSourceIdentifier"] == flavor.inputSourceIdentifier)
        #expect(mine.sets["inputMethodConnectionName"] == flavor.inputMethodConnectionName)
        // The app must carry THIS target and not the other flavor's. Compared by target name,
        // because that is what the app actually names and the only thing that can be wrong
        // independently of everything else here: swap the two `inputMethodTarget:` values and
        // every other check in this suite still passes while each installation ships the
        // other's input source. [LAW:no-silent-failure]
        let app = try #require(installations.first { $0.sets["bundleIdentifier"] == flavor.bundleIdentifier })
        let carried = try #require(app.sets["inputMethodTarget"], "\(flavor)'s app carries no input method target")
        #expect(carried == mine.name,
                "\(flavor)'s app carries the target \(carried), but \(flavor.inputMethodBundleIdentifier) is built by \(mine.name)")
    }

    /// Every block belongs to one flavor and builds under a name that flavor owns, and
    /// each flavor's app bundle is built by exactly one of them.
    ///
    /// The flat `installations.count == Flavor.allCases.count` this replaced would fail
    /// the moment low-input-method-s71.0ae adds a *correct* input method target per
    /// flavor, so what is counted is the blocks building a flavor's own app identifier -
    /// and a block is read by the identifier it sets, never by which attributes it sets,
    /// so that target may name its own `bundleIdentifier` like any other bundle does.
    ///
    /// Both failures the flat count caught outlive it. A target copied wholesale from
    /// release still builds `ai.promptctl.low-talker`, the LaunchServices and TCC
    /// collision this suite's header calls silent in the worst way: that is a second block
    /// under one flavor's identifier. A copy whose author changed the identifier but not
    /// the rest builds a stranger under release's other names: that is a block building
    /// under no name its flavor owns. [LAW:behavior-not-structure]
    @Test func theProjectBuildsNothingThatIsNotAFlavor() throws {
        var appsPerFlavor: [Flavor: Int] = [:]
        for block in try Self.installations() {
            let values = Set(block.sets.values)
            let owners = Flavor.allCases.filter { !Self.names(of: $0).isDisjoint(with: values) }
            #expect(owners.count == 1, "a templateAttributes block names \(owners) rather than one flavor: \(block)")
            guard owners.count == 1, let owner = owners.first else { continue }
            guard let identifier = block.sets["bundleIdentifier"] else { continue }
            #expect(Self.names(of: owner).contains(identifier),
                    "a target builds \(identifier), which is not one of \(owner)'s names: \(block)")
            if identifier == owner.bundleIdentifier { appsPerFlavor[owner, default: 0] += 1 }
        }
        for flavor in Flavor.allCases {
            #expect(appsPerFlavor[flavor, default: 0] == 1,
                    "\(flavor)'s app bundle is built by \(appsPerFlavor[flavor, default: 0]) targets rather than by one")
        }
    }

    /// Every KIND of target is built once per flavor - not just the app.
    ///
    /// The count beside this one is of app blocks alone, which was right while an app was
    /// the only bundle a flavor had. Now that the input method is a target of its own, that
    /// count passes a project.yml carrying a release input method and no development one:
    /// the development installation would build, install and run with no input source at
    /// all, and nothing in the suite would say so. [LAW:no-silent-failure]
    ///
    /// A block's kind is the set of names it SETS, not which template it names: two blocks
    /// setting the same attributes are the same kind of thing said twice, which is exactly
    /// what "one per flavor" is about. [LAW:behavior-not-structure]
    @Test func everyKindOfTargetIsBuiltOncePerFlavor() throws {
        var flavorsByKind: [Set<String>: [Flavor]] = [:]
        for block in try Self.installations() {
            let values = Set(block.sets.values)
            let owners = Flavor.allCases.filter { !Self.names(of: $0).isDisjoint(with: values) }
            guard owners.count == 1, let owner = owners.first else { continue }
            flavorsByKind[Set(block.sets.keys), default: []].append(owner)
        }
        #expect(!flavorsByKind.isEmpty, "project.yml sets no templateAttributes at all")
        for (kind, flavors) in flavorsByKind {
            #expect(Set(flavors) == Set(Flavor.allCases) && flavors.count == Flavor.allCases.count,
                    "the targets setting \(kind.sorted()) are built for \(flavors) rather than once for each flavor")
        }
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
