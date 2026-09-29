import ArgumentParser
import Flavors
import Foundation
import LowTalkerCore
import Testing
@testable import LowTalkerCommands

/// `lowtalker config check`'s exit code is its contract: a script that runs it wants to
/// know whether the file is usable without reading the report. These pin the three
/// answers it can give.
@Suite struct ConfigCheckTests {
    @Test func aFileWithNoGapsExitsZero() throws {
        try withConfig("""
            [[modes]]
            name = "dictation"
            chord = { modifiers = ["rightOption"] }
            """) { check in
            #expect(throws: ExitCode(0)) { try check.run() }
        }
    }

    /// Understood, and still not what its author meant: the file runs, and the mode it
    /// declares turns nothing it hears into anything.
    @Test func aFileWithAGapExitsTwo() throws {
        try withConfig("""
            [[modes]]
            name = "silent"
            chord = { modifiers = ["rightOption"] }
            routes = []
            """) { check in
            #expect(throws: ExitCode(2)) { try check.run() }
        }
    }

    /// [LAW:no-silent-failure] A file that cannot be understood leaves as the error that
    /// says why, which is what puts the sentence and the place in front of its author.
    @Test func aFileThatCannotBeUnderstoodLeavesAsItsError() throws {
        try withConfig(#"modle = "base.en""#) { check in
            #expect(throws: ConfigError.unknownKeys(["modle"])) { try check.run() }
        }
    }

    /// A route naming an app is refused where the file is read: the input method reaches
    /// only the cursor of the app in front, so a check that passed it would be vouching
    /// for a route every press refuses.
    @Test func aRouteNamingAnAppLeavesAsItsError() throws {
        try withConfig("""
            [[modes]]
            name = "slack"
            chord = { modifiers = ["rightOption"] }
            routes = [{ when = "always", then = { insert = { app = "com.tinyspeck.slackmacgap" } } }]
            """) { check in
            #expect(throws: ConfigError.wrongShape(#"modes[0].routes[0].then.insert: insert is the word "focus", the cursor of the app in front: the one place the input method puts text"#)) { try check.run() }
        }
    }

    /// Nothing written at all is not a fault: the report says there is no file and the
    /// defaults are what would run.
    @Test func noFileAtAllExitsZero() throws {
        let missing = URL(filePath: NSTemporaryDirectory()).appending(path: "low-talker-\(UUID().uuidString)/config.toml")
        let check = try ConfigCommand.Check.parse(["--flavor", "release", "--path", missing.path])
        #expect(throws: ExitCode(0)) { try check.run() }
    }

    /// The command is reached the way a user reaches it, so the option name and the
    /// subcommand path are part of what these tests pin.
    private func withConfig(_ toml: String, _ body: (ConfigCommand.Check) throws -> Void) throws {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "low-talker-\(UUID().uuidString).toml")
        try toml.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(try ConfigCommand.Check.parse(["--flavor", "release", "--path", url.path]))
    }
}

/// Which installation a file is read as, when the file is named rather than inferred.
///
/// [LAW:types-are-the-program] `--path` and `--flavor` are one decision - `ConfigSource` -
/// and these pin the half of it that used to be answered by a default nobody typed.
@Suite struct ConfigSourceTests {
    /// The report is about an installation, and with `--path` given there is nothing left
    /// to infer one from. Defaulting filled every absent key from the development copy's
    /// defaults and printed the development chord as the one the *release* app would come
    /// up on - in the one command whose entire job is saying what will run.
    /// [LAW:no-silent-failure]
    @Test func aNamedFileWithNoFlavourIsRefusedRatherThanRead() {
        #expect(throws: ValidationError.self) {
            try ConfigSource(path: URL(filePath: "/tmp/config.toml"), stated: nil)
        }
    }

    @Test(arguments: Flavor.allCases)
    func aNamedFileIsReadAsTheFlavourThatWasStated(flavor: Flavor) throws {
        let source = try ConfigSource(path: URL(filePath: "/tmp/config.toml"), stated: flavor)
        #expect(source.flavor == flavor)
        #expect(source.path?.path == "/tmp/config.toml")
    }

    /// No path is the ordinary case and keeps the documented default: this binary is the
    /// development copy's, so an unqualified command acts on that copy.
    @Test func noPathMeansThisInstallationsOwnFile() throws {
        #expect(try ConfigSource(path: nil, stated: nil).flavor == .development)
        #expect(try ConfigSource(path: nil, stated: nil).path == nil)
        #expect(try ConfigSource(path: nil, stated: .release).flavor == .release)
    }
}
