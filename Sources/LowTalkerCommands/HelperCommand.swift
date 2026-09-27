import ArgumentParser
import Flavors
import Foundation
import Onboarding

/// The keyboard helper as a LaunchDaemon, loaded from the program this CLI shipped with.
///
/// Here, in the binary each app carries, so a Mac with no clone of this repo brings its
/// helper up with the same program that reads where it stands: `lowtalker onboard` reads
/// the job this loads as answering. [LAW:one-source-of-truth]
struct HelperCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "helper",
        abstract: "Load and remove this installation's keyboard helper as a LaunchDaemon, under sudo.",
        discussion: """
            The app registers its helper through Login Items, where it waits for a person to \
            turn it on. This loads the same helper as a LaunchDaemon instead, which needs sudo \
            and no approval: the helper shipped with this lowtalker - Contents/MacOS in its app, \
            or beside it in a build. It refuses to touch the app's own registration.
            """,
        subcommands: [Install.self, Remove.self]
    )

    /// [CLI] Exit 0 once the job holds the helper's Mach service, 1 with the reason otherwise.
    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Load the helper shipped with this lowtalker as the installation's LaunchDaemon.")

        @OptionGroup var installation: FlavorOption

        func run() throws {
            let helper = Carrier.keyboardHelper(shippedWith: URL(fileURLWithPath: LowTalker.path))
            try HelperCommand.say { try HelperJob.install(flavor: installation.flavor, helper: helper) }
        }
    }

    /// [CLI] Exit 0 once no job an install loaded holds the label, 1 with the reason otherwise.
    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Remove the installation's LaunchDaemon job and its plist, never the app's registration.")

        @OptionGroup var installation: FlavorOption

        func run() throws { try HelperCommand.say { try HelperJob.remove(flavor: installation.flavor) } }
    }

    /// Every ending said in one voice on stderr, `lowtalker helper: ...`, exit 0 or 1.
    static func say(_ body: () throws -> String) throws {
        do {
            FileHandle.standardError.write(Data("lowtalker helper: \(try body())\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("lowtalker helper: \(error)\n".utf8))
            throw ExitCode(1)
        }
    }
}
