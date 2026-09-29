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
        #expect(config.gaps == [.modeClaimsNothing(mode: "silent")])
    }

    @Test func aModeWithNoRoutesKeyDictatesAndIsNoGap() throws {
        let config = try Self.config("""
            [[modes]]
            name = "dictation"
            chord = { modifiers = ["rightOption"] }
            """)
        #expect(config.gaps.isEmpty)
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
        #expect(config.gaps == [
            .modeClaimsNothing(mode: "first"),
            .modeClaimsNothing(mode: "second"),
        ])
    }

    // MARK: - The report

    /// The whole of what the command prints for a file that is understood and has no
    /// gaps: where it came from, the model, what the microphone does between presses, where
    /// the server listens, and every mode with its chord, its vocabulary and its routes.
    @Test func theReportReadsTheFileBack() throws {
        let url = URL(filePath: "/tmp/low-talker-example.toml")
        let config = try Self.config("""
            [[modes]]
            name = "dictation"
            chord = { modifiers = ["rightOption"] }
            """)
        let report = ConfigReport(.file(config, at: url, flavor: Self.flavor))
        #expect(report.description == """
            /tmp/low-talker-example.toml

            model: \(ModelName.default)
            microphone: \(MicrophoneAtRest.shut)
            serve: loopback

            mode "dictation"
              chord: rightOption
              vocabulary:
              routes:
                always → insert at the cursor

            gaps:
            """)
    }

    /// [LAW:no-silent-failure] The defaults are a fine thing to run on and a terrible
    /// thing to be shown without being told: a reader who thinks their file was read is
    /// about to debug a file nothing is reading.
    @Test func aReportWithNoFileSaysThereIsNoFile() {
        let url = URL(filePath: "/tmp/low-talker-absent.toml")
        let report = ConfigReport(.noFile(at: url, flavor: Self.flavor))
        #expect(report.description.hasPrefix("no file at /tmp/low-talker-absent.toml, so these are the defaults"))
    }

    /// A chord, a vocabulary and a route are each read back in the words the file
    /// writes them in, so what is printed can be found in the file.
    @Test func aModeIsReadBackInTheWordsTheFileUses() throws {
        let report = ConfigReport(.file(try Self.config(Self.notes), at: URL(filePath: "/tmp/x.toml"), flavor: Self.flavor))
        let lines = report.description.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.contains(#"mode "notes""#))
        #expect(lines.contains("  chord: leftCommand+leftShift"))
        #expect(lines.contains("    Kubernetes"))
        #expect(lines.contains("    always → insert at the cursor"))
    }

    /// The gaps the report holds are the gaps it prints; the command reads the same
    /// list to decide what to exit with.
    @Test func theReportPrintsTheGapsItFound() throws {
        let config = try Self.config("""
            [[modes]]
            name = "silent"
            chord = { modifiers = ["rightOption"] }
            routes = []
            """)
        let report = ConfigReport(.file(config, at: URL(filePath: "/tmp/x.toml"), flavor: Self.flavor))
        #expect(report.gaps == config.gaps)
        #expect(report.description.hasSuffix("""
            gaps:
              mode "silent" has no routes, so nothing said in it becomes anything
            """))
    }

    /// A Set has no order, so a chord with several modifiers has to be given one here
    /// or the report spells it differently from run to run.
    @Test func aChordSpellsItsModifiersTheSameWayEveryTime() {
        let chord = KeyChord(modifiers: .rightOption, .leftCommand, .leftShift)
        #expect("\(chord)" == "leftCommand+leftShift+rightOption")
        #expect("\(KeyChord(modifiers: .rightOption))" == "rightOption")
    }

    private static let notes = """
        [[modes]]
        name = "notes"
        chord = { modifiers = ["leftCommand", "leftShift"] }
        vocabulary = ["Kubernetes"]
        routes = [{ when = "always", then = { insert = "focus" } }]
        """

    /// A bound interface is read back with its address and the fact a token guards it,
    /// never the token: the report is printed, and so is anything pasted from it.
    @Test func theReportNamesTheInterfaceAndNeverTheToken() throws {
        let config = try Self.config("""
            [serve]
            interface = "192.168.1.20"
            token = "sk-report-secret"
            """)
        let report = ConfigReport(.file(config, at: URL(filePath: "/tmp/x.toml"), flavor: Self.flavor)).description
        #expect(report.split(separator: "\n").contains("serve: 192.168.1.20, bearer token required"))
        #expect(!report.contains("sk-report-secret"))
    }
}
