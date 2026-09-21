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
        ("input method bundle identifier", { @Sendable (f: Flavor) in f.inputMethodBundleIdentifier }),
        ("input source identifier", { @Sendable (f: Flavor) in f.inputSourceIdentifier }),
        ("input method connection name", { @Sendable (f: Flavor) in f.inputMethodConnectionName }),
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

    /// Every name macOS files this program under, across both flavors at once.
    ///
    /// `everyFlavorIsNamedApart` asks whether two flavors share one *kind* of name. This
    /// asks the other half: whether two *kinds* collide - the input method bundle taking
    /// the helper's identifier, say, or a development suffix landing one flavor's name on
    /// another flavor's. Both are the same failure to macOS, a second registrant losing to
    /// a first, and neither is caught by comparing a name only to its own kind.
    ///
    /// `launchdLabel` is left out because it is `machServiceName` on purpose, which
    /// `theLabelIsTheService` is what states.
    @Test func noTwoNamesMacOSKeysOnCollide() {
        let names = Flavor.allCases.flatMap { flavor in
            [
                ("bundle identifier", flavor.bundleIdentifier),
                ("Mach service", flavor.machServiceName),
                ("input method bundle identifier", flavor.inputMethodBundleIdentifier),
                ("input source identifier", flavor.inputSourceIdentifier),
                ("input method connection name", flavor.inputMethodConnectionName),
            ].map { (flavor, $0.0, $0.1) }
        }
        #expect(Set(names.map(\.2)).count == names.count, "two names collide: \(names)")
    }

    /// The two grown names stay under the bundle they are grown from, which is what keeps
    /// a source and the server answering for it inside one installation's namespace. A
    /// name spelled apart could be filed under a copy that does not own the bundle
    /// serving it. [LAW:one-source-of-truth]
    @Test(arguments: Flavor.allCases)
    func theInputMethodsNamesAreUnderItsBundle(flavor: Flavor) {
        #expect(flavor.inputSourceIdentifier.hasPrefix(flavor.inputMethodBundleIdentifier + "."))
        #expect(flavor.inputMethodConnectionName.hasPrefix(flavor.inputMethodBundleIdentifier))
        #expect(flavor.inputSourceIdentifier != flavor.inputMethodBundleIdentifier)
        #expect(flavor.inputMethodConnectionName != flavor.inputMethodBundleIdentifier)
    }

    /// The release seed, spelled out once.
    ///
    /// Pinned rather than derived, unlike everything else here, because these strings are
    /// what macOS itself files a registered input source and a published connection under
    /// on somebody's Mac. Changing one is not a rename: it orphans what every installed
    /// copy already registered, and the installed copy is not here to be recompiled. So
    /// the test exists to make that change loud rather than to describe the code.
    @Test func theReleaseSeedIsTheseExactNames() {
        #expect(Flavor.release.inputMethodBundleIdentifier == "ai.promptctl.low-talker.inputmethod")
        #expect(Flavor.release.inputSourceIdentifier == "ai.promptctl.low-talker.inputmethod.dictation")
        #expect(Flavor.release.inputMethodConnectionName == "ai.promptctl.low-talker.inputmethod_Connection")
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
    @Test(arguments: ["", "ai.promptctl.low-talker.staging", "com.apple.Finder", "LowTalker"])
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
