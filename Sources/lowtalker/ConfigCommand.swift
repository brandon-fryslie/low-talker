import AppKit
import ArgumentParser
import Foundation
import LowTalkerCore

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Read the config file the app runs on.",
        subcommands: [Check.self]
    )
}

extension ConfigCommand {
    /// Reads the config file and prints what the app would run with. Nothing is
    /// started: this is the file answered back, so a chord or a route can be checked
    /// before speaking into it.
    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "check",
            abstract: "Print what the app would run with, and what in the config is not what anyone meant.",
            discussion: """
                Exits 0 when the file is understood and has no gaps, 1 when it cannot be \
                understood - naming what is wrong and where in the file it sits - and 2 \
                when it is understood but has gaps. A file that is not there is not a \
                fault: the report says so and prints the defaults.
                """
        )

        @Option(
            help: "The file to read, for checking one before it is installed.",
            transform: URL.init(fileURLWithPath:)
        )
        var path: URL = Config.fileURL

        func run() throws {
            let report = ConfigReport(try Config.load(from: path), appExists: appExists)
            print(report)
            // The code is a value computed the one way every time, rather than an exit
            // taken on some runs and not others. [LAW:dataflow-not-control-flow]
            throw ExitCode(report.gaps.isEmpty ? 0 : 2)
        }

        /// [LAW:effects-at-boundaries] The one question in this command that the machine
        /// answers rather than the file. It lives here, at the edge, so `ConfigReport`
        /// stays a pure function of what the file said and what this returned.
        private func appExists(_ id: BundleID) -> Bool {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id.rawValue) != nil
        }
    }
}
