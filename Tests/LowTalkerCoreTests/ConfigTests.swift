import Foundation
import LowTalkerCore
import Testing

/// The config as the app meets it: what a file says, what an absent file says, and what
/// a file that was written but cannot be understood says instead of running anyway.
@Suite struct ConfigTests {
    /// Every key in the epic's list at once: the engine choice, chords to modes, a
    /// mode's vocabulary, and modes to routes with both places text can go.
    static let full = """
        model = "base.en"

        [[modes]]
        name = "dictation"
        chord = { modifiers = ["rightOption"] }

        [[modes]]
        name = "slack"
        chord = { modifiers = ["leftCommand", "leftShift"], key = 1 }
        vocabulary = ["Kubernetes", "  Anthropic\\n"]
        routes = [
          { when = "always", then = { insert = { app = "com.tinyspeck.slackmacgap" } } },
        ]

        [[modes]]
        name = "notes"
        chord = { modifiers = ["rightCommand"] }
        routes = [{ when = "always", then = { insert = "focus" } }]
        """

    @Test func aFullFileParses() throws {
        let config = try Config(toml: Self.full)
        #expect(config.model == "base.en")
        #expect(config.modes.map(\.name) == ["dictation", "slack", "notes"])

        let slack = try #require(config.modes.first { $0.name == "slack" })
        #expect(slack.chord == KeyChord(key: Key(rawValue: 1), modifiers: [.leftCommand, .leftShift]))
        #expect(slack.vocabulary.terms.map(\.text) == ["Kubernetes", "Anthropic"])
        #expect(slack.router.routes == [
            Route(when: .always, then: .insertTranscript(target: .app(bundleID: BundleID(rawValue: "com.tinyspeck.slackmacgap")))),
        ])

        let notes = try #require(config.modes.first { $0.name == "notes" })
        #expect(notes.router.routes == [Route(when: .always, then: .insertTranscript(target: .focus))])
    }

    /// The whole point of defaults: the app runs with no file written at all.
    @Test func anEmptyFileIsTheDefaults() throws {
        #expect(try Config(toml: "") == .default)
    }

    /// A key the file leaves out is the default for that key alone; naming a model does
    /// not cost you the modes.
    @Test func aKeyLeftOutKeepsItsDefault() throws {
        let config = try Config(toml: #"model = "base.en""#)
        #expect(config.model == "base.en")
        #expect(config.modes == Config.default.modes)
    }

    /// [LAW:one-source-of-truth] The defaults are the values their own owners name, so
    /// this fails the moment a second spelling of one appears.
    @Test func theDefaultsAreTheValuesTheirOwnersName() {
        #expect(Config.default.model == ModelName.default)
        #expect(Config.default.modes == [Mode.dictation])
        #expect(Mode.dictation.chord == Hotkey.defaultChord)
        #expect(Mode.dictation.vocabulary == .empty)
        #expect(Mode.dictation.router.routes == [Route.dictation])
    }

    /// The chord that started listening picks the mode, and the tap is told exactly the
    /// chords the modes claim.
    @Test func theChordSelectsTheMode() throws {
        let config = try Config(toml: Self.full)
        let dictation = KeyChord(modifiers: .rightOption)
        #expect(config.mode(for: dictation)?.name == "dictation")
        #expect(config.mode(for: KeyChord(modifiers: .rightCommand))?.name == "notes")
        #expect(config.mode(for: KeyChord(modifiers: .function)) == nil)
        #expect(config.chords == Set(config.modes.map(\.chord)))
        #expect(config.chords.contains(dictation))
    }

    /// A mode that names no routes dictates: the only thing declaring a chord and a
    /// vocabulary and nothing else could have meant.
    @Test func aModeWithoutRoutesDictates() throws {
        let config = try Config(toml: Self.full)
        let dictation = try #require(config.modes.first)
        #expect(dictation.router.routes == [Route.dictation])
    }

    // MARK: - What a file gets told it did wrong

    /// [LAW:no-silent-failure] A file nobody can read is not a file that says nothing.
    @Test func aFileThatIsNotTOMLNamesTheLineItStoppedOn() throws {
        let error = try #require(throws: ConfigError.self) {
            try Config(toml: "model = \"base.en\"\nthis is not toml\n")
        }
        guard case .notTOML(_, let line) = error else {
            Issue.record("expected notTOML, got \(error)")
            return
        }
        #expect(line == 2)
    }

    /// A misspelled key would otherwise be a line that quietly does nothing.
    @Test func aKeyNothingIsCalledIsNamed() throws {
        let error = try #require(throws: ConfigError.self) {
            try Config(toml: #"modle = "base.en""#)
        }
        guard case .unknownKeys(let keys) = error else {
            Issue.record("expected unknownKeys, got \(error)")
            return
        }
        #expect(keys == ["modle"])
    }

    @Test func aValueOfTheWrongKindNamesItsKey() throws {
        let error = try #require(throws: ConfigError.self) { try Config(toml: "model = 3") }
        #expect("\(error)".contains("model"))
    }

    @Test func aConfigWithNoModesIsRefused() {
        #expect(throws: ConfigError.noModes) { try Config(toml: "modes = []") }
    }

    @Test func aModeWithoutANameIsRefused() {
        #expect(throws: ConfigError.modeUnnamed) {
            try Config(toml: """
                [[modes]]
                name = "  "
                chord = { modifiers = ["rightOption"] }
                """)
        }
    }

    @Test func twoModesWithOneNameAreRefused() {
        #expect(throws: ConfigError.twoModesNamed("dictation")) {
            try Config(toml: """
                [[modes]]
                name = "dictation"
                chord = { modifiers = ["rightOption"] }

                [[modes]]
                name = "dictation"
                chord = { modifiers = ["rightCommand"] }
                """)
        }
    }

    /// Two modes on one chord is a config with no answer to "which mode is this".
    @Test func twoModesOnOneChordAreRefused() {
        #expect(throws: ConfigError.twoModesOnOneChord("second")) {
            try Config(toml: """
                [[modes]]
                name = "first"
                chord = { modifiers = ["rightOption"] }

                [[modes]]
                name = "second"
                chord = { modifiers = ["rightOption"] }
                """)
        }
    }

    /// [LAW:single-enforcer] The rule that a chord has at least one key belongs to
    /// KeyChord, and the config file gets it without restating it - including the
    /// sentence KeyChord wrote.
    @Test func aChordWithNothingInItIsRefusedInKeyChordsOwnWords() throws {
        let error = try #require(throws: ConfigError.self) {
            try Config(toml: """
                [[modes]]
                name = "dictation"
                chord = { modifiers = [] }
                """)
        }
        #expect("\(error)".contains("a chord needs at least one key"))
    }

    /// [LAW:single-enforcer] Likewise the rule about what a vocabulary term may be.
    @Test func aVocabularyTermWithNoWordIsRefused() {
        #expect(throws: VocabularyError.termSaysNothing("...")) {
            try Config(toml: """
                [[modes]]
                name = "dictation"
                chord = { modifiers = ["rightOption"] }
                vocabulary = ["..."]
                """)
        }
    }

    @Test func aRouteMatchingOnSomethingElseIsNamed() {
        #expect(throws: ConfigError.noSuchMatch("sometimes")) {
            try Config(toml: Self.mode(routes: #"[{ when = "sometimes", then = { insert = "focus" } }]"#))
        }
    }

    @Test func aTargetThatIsNowhereIsNamed() {
        #expect(throws: ConfigError.noSuchTarget("wherever")) {
            try Config(toml: Self.mode(routes: #"[{ when = "always", then = { insert = "wherever" } }]"#))
        }
    }

    /// A `then` that names nothing would be a route that claims an utterance and drops
    /// it.
    @Test func aThenNamingNothingIsRefused() {
        #expect(throws: ConfigError.thenNamesNoOneThing) {
            try Config(toml: Self.mode(routes: #"[{ when = "always", then = {} }]"#))
        }
    }

    private static func mode(routes: String) -> String {
        """
        [[modes]]
        name = "dictation"
        chord = { modifiers = ["rightOption"] }
        routes = \(routes)
        """
    }

    // MARK: - Reading the file

    /// No file at all is the one case that yields the defaults.
    @Test func noFileIsTheDefaults() throws {
        let missing = URL(filePath: NSTemporaryDirectory()).appending(path: "low-talker-\(UUID().uuidString)/config.toml")
        #expect(try Config.load(from: missing) == .default)
    }

    @Test func aFileOnDiskIsWhatTheAppRunsOn() throws {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "low-talker-\(UUID().uuidString).toml")
        try Self.full.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Config.load(from: url) == Config(toml: Self.full))
    }

    /// [LAW:no-silent-failure] A path that exists but hands back no config text is an
    /// error, never the defaults: running on settings its owner never chose is the one
    /// outcome a config loader must not have.
    @Test func somethingThatIsNotAReadableFileIsNotTheDefaults() throws {
        let directory = URL(filePath: NSTemporaryDirectory()).appending(path: "low-talker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: (any Error).self) { try Config.load(from: directory) }
    }
}
