import Flavors
import Foundation
import LowTalkerCore
import Testing

/// The config as the app meets it: what a file says, what an absent file says, and what
/// a file that was written but cannot be understood says instead of running anyway.
@Suite struct ConfigTests {
    /// What a file *says* does not depend on which installation read it - only the
    /// defaults behind a key it leaves out do. So these read as the release copy, named
    /// once here instead of at all thirty-odd calls, and the handful of tests that are
    /// actually about the defaults say which installation they mean.
    static let flavor = Flavor.release

    static func config(_ toml: String) throws(ConfigError) -> Config {
        try Config(toml: toml, flavor: flavor)
    }

    /// Every key in the epic's list at once: the engine choice, chords to modes, a
    /// mode's vocabulary, and modes to routes with both places text can go.
    static let full = """
        model = "base.en"

        [microphone]
        at_rest = "open"

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
        let config = try Self.config(Self.full)
        #expect(config.model == "base.en")
        #expect(config.microphone == .open)
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
        #expect(try Self.config("") == Config.default(for: Self.flavor))
    }

    /// A key the file leaves out is the default for that key alone; naming a model does
    /// not cost you the modes.
    @Test func aKeyLeftOutKeepsItsDefault() throws {
        let config = try Self.config(#"model = "base.en""#)
        #expect(config.model == "base.en")
        #expect(config.modes == Config.default(for: Self.flavor).modes)
    }

    /// The epic's rule, pinned where the only writer of it is: a microphone held while
    /// nobody is dictating is one the user asked for in writing. A file that says nothing
    /// about it - which is every file anyone has written so far, and the absence of a file
    /// too - leaves the device closed.
    @Test func aFileThatAsksForNothingLeavesTheMicrophoneShutAtRest() throws {
        #expect(Config.default(for: Self.flavor).microphone == .shut)
        #expect(try Self.config("").microphone == .shut)
        #expect(try Self.config(#"model = "base.en""#).microphone == .shut)
    }

    /// Asking for it is one line, and it is the line the epic wants a user to have to
    /// write on purpose.
    @Test func aFileCanAskForTheMicrophoneToBeHeld() throws {
        #expect(try Self.config("""
            [microphone]
            at_rest = "open"
            """).microphone == .open)
    }

    /// [LAW:no-silent-failure] A resting state nobody can spell is the one place a typo
    /// would decide whether the device is open, so it is refused in the word the file
    /// wrote rather than falling back to either reading.
    @Test func aWordThatIsNotARestingStateIsRefused() {
        #expect(throws: ConfigError.wrongShape(#"microphone.at_rest: "sometimes" is not something the microphone does at rest"#)) {
            try Self.config("""
                [microphone]
                at_rest = "sometimes"
                """)
        }
    }

    /// A heading with nothing under it is a file whose author meant something by writing
    /// it, and the one thing it cannot be read as is the default they were already getting.
    @Test func aMicrophoneTableThatSaysNothingIsRefused() {
        #expect(throws: ConfigError.wrongShape("microphone.at_rest is missing")) {
            try Self.config("[microphone]")
        }
    }

    /// [LAW:one-source-of-truth] The defaults are the values their own owners name, so
    /// this fails the moment a second spelling of one appears.
    ///
    /// Over every installation rather than one, because the defaults are per-installation
    /// now: a chord wired to `.release` behind any of these would pass a release-only
    /// check and still bring the two copies up listening for one chord.
    @Test(arguments: Flavor.allCases) func theDefaultsAreTheValuesTheirOwnersName(_ flavor: Flavor) {
        #expect(Config.default(for: flavor).model == ModelName.default)
        #expect(Config.default(for: flavor).modes == [Mode.dictation(for: flavor)])
        #expect(Mode.dictation(for: flavor).chord == Hotkey.defaultChord(for: flavor))
        #expect(Mode.dictation(for: flavor).vocabulary == .empty)
        #expect(Mode.dictation(for: flavor).router.routes == [Route.dictation])
    }

    /// The chord that started listening picks the mode, and the tap is told exactly the
    /// chords the modes claim.
    @Test func theChordSelectsTheMode() throws {
        let config = try Self.config(Self.full)
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
        let config = try Self.config(Self.full)
        let dictation = try #require(config.modes.first)
        #expect(dictation.router.routes == [Route.dictation])
    }

    // MARK: - What a file gets told it did wrong

    /// [LAW:no-silent-failure] A file nobody can read is not a file that says nothing.
    @Test func aFileThatIsNotTOMLNamesTheLineItStoppedOn() throws {
        let error = try #require(throws: ConfigError.self) {
            try Self.config("model = \"base.en\"\nthis is not toml\n")
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
            try Self.config(#"modle = "base.en""#)
        }
        guard case .unknownKeys(let keys) = error else {
            Issue.record("expected unknownKeys, got \(error)")
            return
        }
        #expect(keys == ["modle"])
    }

    @Test func aValueOfTheWrongKindNamesItsKey() throws {
        let error = try #require(throws: ConfigError.self) { try Self.config("model = 3") }
        #expect("\(error)".contains("model"))
    }

    @Test func aConfigWithNoModesIsRefused() {
        #expect(throws: ConfigError.noModes) { try Self.config("modes = []") }
    }

    @Test func aModeWithoutANameIsRefused() {
        #expect(throws: ConfigError.modeUnnamed) {
            try Self.config("""
                [[modes]]
                name = "  "
                chord = { modifiers = ["rightOption"] }
                """)
        }
    }

    @Test func twoModesWithOneNameAreRefused() {
        #expect(throws: ConfigError.twoModesNamed("dictation")) {
            try Self.config("""
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
            try Self.config("""
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
            try Self.config("""
                [[modes]]
                name = "dictation"
                chord = { modifiers = [] }
                """)
        }
        #expect("\(error)".contains("a chord needs at least one key"))
    }

    /// [LAW:single-enforcer] Likewise the rule about what a vocabulary term may be.
    @Test func aVocabularyTermWithNoWordIsRefused() {
        #expect(throws: ConfigError.wrongShape(#"modes[0].vocabulary[0]: vocabulary term "..." has no word in it"#)) {
            try Self.config("""
                [[modes]]
                name = "dictation"
                chord = { modifiers = ["rightOption"] }
                vocabulary = ["..."]
                """)
        }
    }

    @Test func aRouteMatchingOnSomethingElseIsNamed() {
        #expect(throws: ConfigError.wrongShape(#"modes[0].routes[0].when: "sometimes" is not something a route can match on"#)) {
            try Self.config(Self.mode(routes: #"[{ when = "sometimes", then = { insert = "focus" } }]"#))
        }
    }

    @Test func aTargetThatIsNowhereIsNamed() {
        #expect(throws: ConfigError.wrongShape(#"modes[0].routes[0].then.insert: "wherever" is not somewhere text can be inserted"#)) {
            try Self.config(Self.mode(routes: #"[{ when = "always", then = { insert = "wherever" } }]"#))
        }
    }

    /// A `then` that names nothing would be a route that claims an utterance and drops
    /// it.
    @Test func aThenNamingNothingIsRefused() {
        #expect(throws: ConfigError.wrongShape("modes[0].routes[0].then.insert is missing")) {
            try Self.config(Self.mode(routes: #"[{ when = "always", then = {} }]"#))
        }
    }

    /// A `then` whose one key is misspelled named exactly one thing, so it is told which
    /// key is absent rather than that it named nothing.
    @Test func aThenWhoseOnlyKeyIsMisspelledIsToldWhatIsMissing() {
        #expect(throws: ConfigError.wrongShape("modes[0].routes[0].then.insert is missing")) {
            try Self.config(Self.mode(routes: #"[{ when = "always", then = { emit = "focus" } }]"#))
        }
    }

    /// A misspelling beside a valid `insert` is named, because the decode completes and
    /// leaves the stray key for strict decoding to find.
    @Test func aThenWithAKeyBesideInsertNamesIt() {
        #expect(throws: ConfigError.unknownKeys(["modes[0].routes[0].then.emit"])) {
            try Self.config(Self.mode(routes: #"[{ when = "always", then = { insert = "focus", emit = "focus" } }]"#))
        }
    }

    /// The position has to be counted, not assumed: the fault is in the second route
    /// of the second mode, so a hardcoded `modes[0].routes[0]` would fail here.
    @Test func aRouteFaultNamesWhichModeAndWhichRouteItIsIn() {
        #expect(throws: ConfigError.wrongShape(#"modes[1].routes[1].when: "sometyme" is not something a route can match on"#)) {
            try Self.config("""
                [[modes]]
                name = "dictation"
                chord = { modifiers = ["rightOption"] }

                [[modes]]
                name = "slack"
                chord = { modifiers = ["rightCommand"] }
                routes = [
                  { when = "always", then = { insert = "focus" } },
                  { when = "sometyme", then = { insert = "focus" } },
                ]
                """)
        }
    }

    /// [LAW:no-silent-failure] Strict decoding reaches into the hand-written decoders
    /// for `then` and `insert`, so a typo nested that deep is named rather than quietly
    /// dropped. Pinned by test because the guarantee is TOMLKit's, not this package's.
    @Test func aTypoBesideAValidInsertIsNamed() {
        #expect(throws: ConfigError.unknownKeys(["modes[0].routes[0].then.isnert"])) {
            try Self.config(Self.mode(routes: #"[{ when = "always", then = { insert = "focus", isnert = "y" } }]"#))
        }
    }

    @Test func aTypoInsideInsertIsNamed() {
        #expect(throws: ConfigError.unknownKeys(["modes[0].routes[0].then.insert.typo"])) {
            try Self.config(Self.mode(routes: #"[{ when = "always", then = { insert = { app = "com.tinyspeck.slackmacgap", typo = 1 } } }]"#))
        }
    }

    /// A fault inside a route is placed the way the file writes routes: by position,
    /// each key named once.
    @Test func aFaultInsideARouteNamesWhereItIs() {
        #expect(throws: ConfigError.wrongShape("modes[0].routes[0].when is missing")) {
            try Self.config(Self.mode(routes: #"[{ then = { insert = "focus" } }]"#))
        }
    }

    /// Which `[[modes]]` entry is at fault, counted as the file lists them.
    @Test func aMissingKeyNamesTheModeItIsIn() {
        #expect(throws: ConfigError.wrongShape("modes[1].chord is missing")) {
            try Self.config("""
                [[modes]]
                name = "dictation"
                chord = { modifiers = ["rightOption"] }

                [[modes]]
                name = "slack"
                """)
        }
    }

    /// [LAW:single-enforcer] The sentence is ModelName's own, so it speaks of model
    /// names rather than of the Swift type the parser happened to be building.
    @Test func aModelNameThatIsNotOneIsRefusedInItsOwnWords() {
        #expect(throws: ConfigError.wrongShape(#"model: ".." is not a model name: one folder in the model repo, such as base.en"#)) {
            try Self.config(#"model = "..""#)
        }
    }

    /// A modifier that is not one is answered with the ones that are.
    @Test func aModifierThatIsNotOneIsNamedWithTheOnesThatAre() {
        let modifiers = Modifier.allCases.map(\.rawValue).joined(separator: ", ")
        #expect(throws: ConfigError.wrongShape(#"modes[0].chord.modifiers[0]: "banana" is not a modifier: "# + modifiers)) {
            try Self.config("""
                [[modes]]
                name = "dictation"
                chord = { modifiers = ["banana"] }
                """)
        }
    }

    /// A typo is placed like every other fault, so two of them in different modes are
    /// each named where they sit rather than as bare words.
    @Test func typosInDifferentModesAreEachPlaced() {
        #expect(throws: ConfigError.unknownKeys(["modes[0].chrod", "modes[1].vocabualry"])) {
            try Self.config("""
                [[modes]]
                name = "a"
                chord = { modifiers = ["rightOption"] }
                chrod = 1

                [[modes]]
                name = "b"
                chord = { modifiers = ["rightCommand"] }
                vocabualry = ["x"]
                """)
        }
    }

    /// [LAW:no-silent-failure] TOMLKit keys its unexpected-key report by name, so one
    /// misspelling made twice arrives as a single entry - the second is lost before this
    /// package sees it. The file is still refused and the entry that survives says
    /// exactly where it is, so the other surfaces on the next run. Pinned so that a
    /// TOMLKit that starts reporting both fails here rather than going unnoticed.
    @Test func oneMisspellingRepeatedArrivesOncePlaced() {
        let error = #expect(throws: ConfigError.self) {
            try Self.config("""
                [[modes]]
                name = "a"
                chord = { modifiers = ["rightOption"] }
                chrod = 1

                [[modes]]
                name = "b"
                chord = { modifiers = ["rightCommand"] }
                chrod = 2
                """)
        }
        guard case .unknownKeys(let keys)? = error else {
            Issue.record("expected .unknownKeys, got \(String(describing: error))")
            return
        }
        #expect(keys.count == 1)
        #expect(keys.first?.hasSuffix(".chrod") == true)
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

    /// No file at all is the one case that yields the defaults - and says it did, so a
    /// reader is never shown the defaults as though somebody had written them.
    @Test func noFileIsTheDefaults() throws {
        let missing = URL(filePath: NSTemporaryDirectory()).appending(path: "low-talker-\(UUID().uuidString)/config.toml")
        #expect(try Config.load(missing, for: Self.flavor) == .noFile(at: missing, flavor: Self.flavor))
        #expect(try Config.load(missing, for: Self.flavor).config == Config.default(for: Self.flavor))
    }

    /// A file that says exactly what the defaults say is still a file somebody wrote,
    /// and the two are told apart by which case they arrive in rather than by comparing
    /// configs - which could not tell them apart at all.
    @Test func aFileSayingTheDefaultsIsStillAFile() throws {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "low-talker-\(UUID().uuidString).toml")
        try "".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Config.load(url, for: Self.flavor) == .file(Config.default(for: Self.flavor), at: url, flavor: Self.flavor))
    }

    @Test func aFileOnDiskIsWhatTheAppRunsOn() throws {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "low-talker-\(UUID().uuidString).toml")
        try Self.full.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Config.load(url, for: Self.flavor) == .file(Self.config(Self.full), at: url, flavor: Self.flavor))
    }

    /// [LAW:no-silent-failure] A path that exists but hands back no config text is an
    /// error, never the defaults: running on settings its owner never chose is the one
    /// outcome a config loader must not have.
    @Test func somethingThatIsNotAReadableFileIsNotTheDefaults() throws {
        let directory = URL(filePath: NSTemporaryDirectory()).appending(path: "low-talker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: ConfigError.self) { try Config.load(directory, for: Self.flavor) }
    }

    /// A file saved in some other encoding is a file whose owner needs to be told which
    /// file, in the words the system used - not handed a Foundation error they have no
    /// use for, and not quietly given somebody else's settings.
    @Test func aFileThatCannotBeReadIsNamedRatherThanReplaced() throws {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "low-talker-\(UUID().uuidString).toml")
        try Data([0xFF, 0xFE, 0xFD]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let error = #expect(throws: ConfigError.self) { try Config.load(url, for: Self.flavor) }
        guard case .unreadable(let path, _)? = error else {
            Issue.record("expected .unreadable, got \(String(describing: error))")
            return
        }
        #expect(path == url.path)
    }
}
