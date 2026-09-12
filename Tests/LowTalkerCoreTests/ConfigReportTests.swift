import Flavors
import Foundation
import LowTalkerCore
import Testing

/// What `lowtalker config check` finds and what it prints: the faults that are not a
/// `ConfigError` because the file was understood, and the config read back to the
/// person who wrote it.
@Suite struct ConfigReportTests {
    /// What a report *says* about a file does not depend on which installation read it,
    /// so these read as the release copy, named once here. [LAW:one-source-of-truth]
    static let flavor = Flavor.release

    static func config(_ toml: String) throws(ConfigError) -> Config {
        try Config(toml: toml, flavor: flavor)
    }

    /// Nothing installed, so every bundle id a config names is one this Mac does not
    /// have. The predicate is a value, which is why these tests say the same thing on a
    /// machine with Slack and a machine without it.
    static func noApps(_ app: BundleID) -> Bool { false }

    // MARK: - Gaps

    /// The two files this distinguishes look almost alike and mean different things: an
    /// empty `routes` list claims nothing, and no `routes` key at all dictates.
    @Test func aModeWithAnEmptyRouteListClaimsNothing() throws {
        let config = try Self.config("""
            [[modes]]
            name = "dictation"
            chord = { modifiers = ["rightOption"] }

            [[modes]]
            name = "silent"
            chord = { modifiers = ["rightCommand"] }
            routes = []
            """)
        #expect(config.gaps(appExists: Self.noApps) == [.modeClaimsNothing(mode: "silent")])
    }

    @Test func aModeWithNoRoutesKeyDictatesAndIsNoGap() throws {
        let config = try Self.config("""
            [[modes]]
            name = "dictation"
            chord = { modifiers = ["rightOption"] }
            """)
        #expect(config.gaps(appExists: Self.noApps).isEmpty)
    }

    /// [LAW:parse-dont-validate] `BundleID` takes any string on purpose - whether an app
    /// exists is a fact about this Mac, not about the file - so this is the one place
    /// that fact is checked, and it is checked against an answer handed in.
    @Test func aRouteIntoAnAppThisMacDoesNotHaveIsNamed() throws {
        let config = try Self.config(Self.slack)
        #expect(config.gaps(appExists: Self.noApps) == [
            .noSuchApp(mode: "slack", app: BundleID(rawValue: "com.tinyspeck.slackmacgap")),
        ])
    }

    @Test func aRouteIntoAnAppThisMacHasIsNoGap() throws {
        let config = try Self.config(Self.slack)
        #expect(config.gaps(appExists: { $0.rawValue == "com.tinyspeck.slackmacgap" }).isEmpty)
    }

    /// One missing app is one thing to fix, however many routes mention it.
    @Test func oneMissingAppNamedTwiceIsReportedOnce() throws {
        let config = try Self.config("""
            [[modes]]
            name = "slack"
            chord = { modifiers = ["rightOption"] }
            routes = [
              { when = "always", then = { insert = { app = "com.tinyspeck.slackmacgap" } } },
              { when = "always", then = { insert = { app = "com.tinyspeck.slackmacgap" } } },
            ]
            """)
        #expect(config.gaps(appExists: Self.noApps).count == 1)
    }

    /// Gaps come back in the order the file declares its modes, so two runs over one
    /// file produce the same report and a reader can find the mode being spoken of.
    @Test func gapsArriveInTheOrderTheFileDeclaresModes() throws {
        let config = try Self.config("""
            [[modes]]
            name = "first"
            chord = { modifiers = ["rightOption"] }
            routes = []

            [[modes]]
            name = "second"
            chord = { modifiers = ["rightCommand"] }
            routes = []
            """)
        #expect(config.gaps(appExists: Self.noApps) == [
            .modeClaimsNothing(mode: "first"),
            .modeClaimsNothing(mode: "second"),
        ])
    }

    // MARK: - The report

    /// The whole of what the command prints for a file that is understood and has no
    /// gaps: where it came from, the model, what the microphone does between presses, and
    /// every mode with its chord, its vocabulary and its routes.
    @Test func theReportReadsTheFileBack() throws {
        let url = URL(filePath: "/tmp/low-talker-example.toml")
        let config = try Self.config("""
            [[modes]]
            name = "dictation"
            chord = { modifiers = ["rightOption"] }
            """)
        let report = ConfigReport(.file(config, at: url, flavor: Self.flavor), appExists: Self.noApps)
        #expect(report.description == """
            /tmp/low-talker-example.toml

            model: \(ModelName.default)
            microphone: \(MicrophoneAtRest.shut)

            mode "dictation"
              chord: rightOption
              vocabulary:
              routes:
                always → insert into the focused element

            gaps:
            """)
    }

    /// [LAW:no-silent-failure] The defaults are a fine thing to run on and a terrible
    /// thing to be shown without being told: a reader who thinks their file was read is
    /// about to debug a file nothing is reading.
    @Test func aReportWithNoFileSaysThereIsNoFile() {
        let url = URL(filePath: "/tmp/low-talker-absent.toml")
        let report = ConfigReport(.noFile(at: url, flavor: Self.flavor), appExists: Self.noApps)
        #expect(report.description.hasPrefix("no file at /tmp/low-talker-absent.toml, so these are the defaults"))
    }

    /// A chord, a vocabulary and a route are each read back in the words the file
    /// writes them in, so what is printed can be found in the file.
    @Test func aModeIsReadBackInTheWordsTheFileUses() throws {
        let report = ConfigReport(.file(try Self.config(Self.slack), at: URL(filePath: "/tmp/x.toml"), flavor: Self.flavor), appExists: { _ in true })
        let lines = report.description.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.contains(#"mode "slack""#))
        #expect(lines.contains("  chord: leftCommand+leftShift+key 1"))
        #expect(lines.contains("    Kubernetes"))
        #expect(lines.contains("    always → insert into com.tinyspeck.slackmacgap"))
    }

    /// The gaps the report holds are the gaps it prints; the command reads the same
    /// list to decide what to exit with.
    @Test func theReportPrintsTheGapsItFound() throws {
        let config = try Self.config(Self.slack)
        let report = ConfigReport(.file(config, at: URL(filePath: "/tmp/x.toml"), flavor: Self.flavor), appExists: Self.noApps)
        #expect(report.gaps == config.gaps(appExists: Self.noApps))
        #expect(report.description.hasSuffix("""
            gaps:
              mode "slack" inserts into com.tinyspeck.slackmacgap, which no app on this Mac answers to
            """))
    }

    /// A Set has no order, so a chord with several modifiers has to be given one here
    /// or the report spells it differently from run to run.
    @Test func aChordSpellsItsModifiersTheSameWayEveryTime() {
        let chord = KeyChord(key: Key(rawValue: 1), modifiers: [.rightOption, .leftCommand, .leftShift])
        #expect("\(chord)" == "leftCommand+leftShift+rightOption+key 1")
        #expect("\(KeyChord(modifiers: .rightOption))" == "rightOption")
    }

    private static let slack = """
        [[modes]]
        name = "slack"
        chord = { modifiers = ["leftCommand", "leftShift"], key = 1 }
        vocabulary = ["Kubernetes"]
        routes = [{ when = "always", then = { insert = { app = "com.tinyspeck.slackmacgap" } } }]
        """
}
