import Testing

@testable import Flavors

/// What has to hold for two installations to run at the same time.
///
/// [LAW:behavior-not-structure] Every check here is over `allCases` rather than over the
/// two names spelled out, so the contract is asserted about flavors as such: a third one
/// added later is held to the same rules without a line being written here.
struct FlavorTests {
    /// The whole point of the type. Each of these is a namespace macOS enforces
    /// uniqueness in, and any two flavors sharing one entry is the second copy failing
    /// to run rather than running beside the first.
    @Test(arguments: [
        ("bundle identifier", { @Sendable (f: Flavor) in f.bundleIdentifier }),
        ("Mach service", { @Sendable (f: Flavor) in f.machServiceName }),
        ("launchd label", { @Sendable (f: Flavor) in f.launchdLabel }),
        ("display name", { @Sendable (f: Flavor) in f.displayName }),
        ("config file", { @Sendable (f: Flavor) in f.configFileName }),
    ] as [(String, @Sendable (Flavor) -> String)])
    func everyFlavorIsNamedApart(named: String, read: @Sendable (Flavor) -> String) {
        let names = Flavor.allCases.map(read)
        #expect(Set(names).count == Flavor.allCases.count, "two flavors share a \(named): \(names)")
        let empty = names.filter(\.isEmpty)
        #expect(empty.isEmpty, "a flavor has an empty \(named)")
    }

    /// The rule the measured launchd behaviour rests on: one label per flavor, and it is
    /// the service's own name. Two labels naming one service is the collision that
    /// bootstraps with exit 0 and never receives the endpoint.
    @Test(arguments: Flavor.allCases)
    func theLabelIsTheService(flavor: Flavor) {
        #expect(flavor.launchdLabel == flavor.machServiceName)
    }

    /// [LAW:parse-dont-validate] What the app reads off its own bundle comes back as the
    /// flavor that bundle is.
    @Test(arguments: Flavor.allCases)
    func aBundleIdentifierReadsBackAsItsFlavor(flavor: Flavor) {
        #expect(Flavor(bundleIdentifier: flavor.bundleIdentifier) == flavor)
    }

    /// An identifier belonging to neither is refused rather than guessed at: answering
    /// `.release` for it would point a misbuilt app at the installed copy's helper,
    /// config and hotkey.
    @Test(arguments: ["", "ltd.deadgrass.low-talker.staging", "com.apple.Finder", "LowTalker"])
    func anUnknownBundleIdentifierIsRefused(identifier: String) {
        #expect(Flavor(bundleIdentifier: identifier) == nil)
    }

    /// The word the plist passes and the CLI takes, in both directions.
    @Test(arguments: Flavor.allCases)
    func aFlavorReadsBackFromItsWord(flavor: Flavor) {
        #expect(Flavor(word: flavor.description) == flavor)
    }

    @Test(arguments: ["", "dev", "Release", "prod", "release "])
    func anUnknownWordIsRefused(word: String) {
        #expect(Flavor(word: word) == nil)
    }
}
