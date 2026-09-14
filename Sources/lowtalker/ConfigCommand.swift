import AppKit
import ArgumentParser
import Flavors
import Foundation
import LowTalkerCore

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Read the config file the app runs on.",
        subcommands: [Check.self, Watch.self]
    )
}

/// [LAW:effects-at-boundaries] The one question these commands ask of the machine rather
/// than of the file, at the edge, so `ConfigReport` stays a pure function of what the
/// file said and what this returned. [LAW:one-source-of-truth] `check` and `watch` print
/// the same report, so they ask it the same way.
private func appExists(_ id: BundleID) -> Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: id.rawValue) != nil
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

        @OptionGroup var installation: FlavorOption

        /// Absent means this installation's own file, which is what `ConfigSource` reads
        /// this and `--flavor` into: present, it obliges the caller to say which
        /// installation the file belongs to rather than inheriting a default that decides
        /// every key the file leaves out.
        @Option(
            help: "The file to read, for checking one before it is installed.",
            transform: URL.init(fileURLWithPath:)
        )
        var path: URL?

        func run() throws {
            let source = try ConfigSource(path: path, stated: installation.stated)
            let report = ConfigReport(try Config.load(source.path, for: source.flavor), appExists: appExists)
            print(report)
            // The code is a value computed the one way every time, rather than an exit
            // taken on some runs and not others. [LAW:dataflow-not-control-flow]
            throw ExitCode(report.gaps.isEmpty ? 0 : 2)
        }
    }

    /// The same reading as `check`, kept up as the file is edited, so a chord can be
    /// changed and seen to take effect before the app is wired to do it.
    struct Watch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "watch",
            abstract: "Print what the app would run with, then every change to it until interrupted.",
            discussion: """
                Prints the report `check` prints, then stays up and prints it again each \
                time the file is saved into something different. A save that cannot be \
                understood is named and the config already running is kept, so a syntax \
                error mid-edit costs nothing. Deleting \
                the file goes back to the defaults, and creating one where there was none \
                is picked up as well.
                """
        )

        @OptionGroup var installation: FlavorOption

        /// Absent means this installation's own file, resolved as in `check`.
        @Option(
            help: "The file to watch, for trying one out before it is installed.",
            transform: URL.init(fileURLWithPath:)
        )
        var path: URL?

        func run() async throws {
            setvbuf(stdout, nil, _IOLBF, 0)
            // A config that cannot be read now has no previous config to keep, so it is
            // the same refusal `check` makes and exits the same way. Only what happens
            // after the first reading is a reload.
            let source = try ConfigSource(path: path, stated: installation.stated)
            let loaded = try Config.load(source.path, for: source.flavor)
            print(ConfigReport(loaded, appExists: appExists))
            for await reload in Config.reloads(after: loaded) {
                print(Self.narration(of: reload, appExists: appExists))
            }
        }

        /// What one reload reads as on the way past.
        ///
        /// [LAW:effects-at-boundaries] The whole of what this command says, with no
        /// printing in it, so a test reads what a watcher sees instead of driving a file
        /// and catching stdout to find out.
        static func narration(of reload: Config.Reload, appExists: (BundleID) -> Bool) -> String {
            // A blank line first, so a run of these reads as several reports and not one
            // long one.
            switch reload {
            case .adopted(let loaded):
                "\n\(ConfigReport(loaded, appExists: appExists))"
            case .kept(let loaded, let error):
                // The error first, because it is the news; what is still running second,
                // because that is the reassurance.
                "\nrefused: \(error)\nstill running: \(loaded)"
            }
        }
    }
}
