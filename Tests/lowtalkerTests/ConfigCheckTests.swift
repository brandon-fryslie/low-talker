import ArgumentParser
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
        let check = try ConfigCommand.Check.parse(["--path", missing.path])
        #expect(throws: ExitCode(0)) { try check.run() }
    }

    /// The command is reached the way a user reaches it, so the option name and the
    /// subcommand path are part of what these tests pin.
    private func withConfig(_ toml: String, _ body: (ConfigCommand.Check) throws -> Void) throws {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "low-talker-\(UUID().uuidString).toml")
        try toml.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(try ConfigCommand.Check.parse(["--path", url.path]))
    }
}
