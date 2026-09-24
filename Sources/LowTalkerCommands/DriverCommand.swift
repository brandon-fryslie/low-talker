import ArgumentParser
import DriverExtension
import Foundation

/// The virtual keyboard's driver extension on this Mac: where it stands, and the verbs
/// that put it there and take it off.
///
/// All of it is here, in the binary each app carries, so a Mac with no clone of this repo
/// installs the driver with the same program that reads its state, and the menu-bar app
/// names the same verbs. [LAW:one-source-of-truth]
struct DriverCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "driver",
        abstract: "Read, install and remove the virtual keyboard's driver extension.",
        subcommands: [State.self, Expect.self, Install.self, Remove.self, Fetch.self, Check.self, Registered.self, Receipt.self, Pins.self]
    )
}

extension DriverCommand {
    /// Asserts the verdict `state` would print, for a caller that wants a machine in one
    /// state before going on.
    struct Expect: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "expect",
            abstract: "Exit 0 when the driver is in the named state, and 1 saying what it is instead."
        )

        @Argument(help: "One of: \(DriverState.allCases.map(\.rawValue).joined(separator: ", ")).")
        var verdict: DriverState

        func run() throws {
            // An unreadable machine is the `unknown` verdict, as `state` prints it, with the
            // reason said first; the comparison below then speaks for it.
            let got: DriverState
            do { got = DriverState(try DriverProbe.facts()) } catch {
                FileHandle.standardError.write(Data("lowtalker driver: \(error)\n".utf8))
                got = .unknown
            }
            guard got == verdict else { throw DriverVerb.refused("expected the driver to be '\(verdict.rawValue)' but it is '\(got.rawValue)'") }
            FileHandle.standardError.write(Data("lowtalker driver: confirmed '\(verdict.rawValue)'\n".utf8))
        }
    }

    /// [CLI] Exit 0 when the driver is active, 2 when it waits on the approval click, and 1
    /// when the install could not do its part.
    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Install the pinned driver package and ask macOS to activate it.",
            discussion: """
                Downloads the pinned package, or takes the one named - such as the copy a \
                release carries in Contents/Resources - verifies its checksum and signature, \
                installs it with sudo, and asks macOS to activate the driver as you. Run it as \
                yourself, not under sudo: the approval you give answers the request of whoever \
                asked. Exits 0 when the driver is active, 2 when it waits for your approval \
                in System Settings, and 1 otherwise.
                """
        )

        @Argument(help: "A package file to install instead of downloading one.", completion: .file())
        var package: String?

        func run() throws {
            try DriverVerb.end(DriverVerb.refusing { try DriverInstall.install(from: package.map { URL(fileURLWithPath: $0) }, cli: LowTalker.path) })
        }
    }

    /// [CLI] Exit 0 when the driver is gone, 2 when only a restart is left, and 1 when the
    /// removal refused.
    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Deactivate the driver extension, delete its files and forget its receipt.",
            discussion: "Exits 0 when the driver is gone, 2 when macOS keeps it registered until a restart, and 1 otherwise."
        )

        func run() throws { try DriverVerb.end(DriverVerb.refusing { try DriverInstall.remove(cli: LowTalker.path) }) }
    }

    /// [CLI] The copy's path on stdout, and nothing else there, so a build can capture it.
    struct Fetch: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "fetch",
            abstract: "Download and verify the pinned package into a directory, for a release to carry."
        )

        @Argument(help: "The directory to put the package in.", completion: .directory)
        var directory: String

        func run() throws {
            print(try DriverVerb.refusing { try DriverInstall.fetch(into: URL(fileURLWithPath: directory)) }.path)
        }
    }

    /// Judges a package file where it lies, for a build checking what it put in a bundle.
    /// An install never trusts this verdict: it copies the file and judges the copy.
    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "check",
            abstract: "Verify a package file against the pinned checksum and signature."
        )

        @Argument(help: "The package file.", completion: .file())
        var package: String

        func run() throws {
            _ = try DriverVerb.refusing { try DriverPackage.verify(URL(fileURLWithPath: package), as: "the package at \(package)") }
            FileHandle.standardError.write(Data("lowtalker driver: \(package) is the pinned package \(DriverPackage.version)\n".utf8))
        }
    }
}

extension DriverState: ExpressibleByArgument {}

/// How the driver verbs leave the process, in one place so every verb exits the same way.
private enum DriverVerb {
    static func end(_ ending: DriverInstall.Ending) throws {
        switch ending {
        case .done(let said):
            FileHandle.standardError.write(Data("lowtalker driver: \(said)\n".utf8))
        case .waitingOnAPerson(let said):
            FileHandle.standardError.write(Data("\nlowtalker driver: \(said)\n".utf8))
            throw ExitCode(2)
        }
    }

    /// A refusal printed as the sentence it is, exit 1.
    static func refused(_ said: String) -> ExitCode {
        FileHandle.standardError.write(Data("lowtalker driver: \(said)\n".utf8))
        return ExitCode(1)
    }

    static func refusing<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let refusal as DriverInstallRefusal { throw refused(refusal.description) }
    }
}

extension DriverCommand {
    /// The whole machine in one word.
    ///
    /// [CLI] The fact table goes to stderr for a reader and the verdict alone to stdout
    /// for a caller, so `$(lowtalker driver state)` is exactly the verdict. Exit 0 says a
    /// reading was taken, not that the driver is well; exit 1 says the machine could not
    /// be read, and the word on stdout is then `unknown`. [LAW:no-silent-failure]
    struct State: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "state",
            abstract: "Print the readings to stderr and one verdict word to stdout.",
            discussion: """
                The verdicts are absent, installed-inactive, awaiting-approval, disabled, \
                enabled, running, pending-reboot, residue, and unknown. `enabled` means \
                macOS has the extension switched on; `running` means that and the driver \
                has published its node in the IORegistry.
                """
        )

        func run() throws {
            // A machine that could not be read never becomes a verdict about the driver.
            // The word still goes to stdout, because a caller reading this command's
            // output deserves a word rather than an empty string interpolated into its
            // next command, and the non-zero exit is what says not to trust it.
            do {
                let facts = try DriverProbe.facts()
                let state = DriverState(facts)
                // The verdict is shown beside the readings it came from as well as
                // returned on stdout: a verdict nobody can check against its inputs is a
                // verdict nobody can debug. Rendered once, from one value.
                FileHandle.standardError.write(Data("\(facts)\nverdict            \(state.rawValue)\n".utf8))
                print(state.rawValue)
            } catch {
                FileHandle.standardError.write(Data("lowtalker driver: \(error)\n".utf8))
                print(DriverState.unknown.rawValue)
                throw ExitCode(1)
            }
        }
    }

    /// The registration alone, which is the one fact removal reasons about by itself:
    /// only a live registration needs withdrawing, and only the withdrawal needs the
    /// Manager app that removal is about to delete.
    struct Registered: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "registration",
            abstract: "Print how macOS has the driver extension registered, as one word."
        )

        func run() throws {
            do {
                print(try DriverProbe.registration().rawValue)
            } catch {
                FileHandle.standardError.write(Data("lowtalker driver: \(error)\n".utf8))
                print(DriverExtension.Registration.unknown.rawValue)
                throw ExitCode(1)
            }
        }
    }
}

extension DriverCommand {
    /// Every constant this program holds about the driver extension, as
    /// `name<TAB>value` lines.
    ///
    /// [LAW:one-source-of-truth] README.md names some of these, because a reader follows
    /// the runbook by hand. It cannot read a Swift constant, so it keeps copies and
    /// `make check-docs` reads this to prove they still agree.
    struct Pins: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pins",
            abstract: "Print every constant this program holds about the driver extension."
        )

        func run() {
            let pins = [
                ("bundle-id", DriverProbe.bundleID),
                ("team-id", DriverProbe.teamID),
                ("io-node", DriverProbe.ioNodeName),
                ("elements-receipt", DriverProbe.elementsReceiptID),
                ("manager-app", DriverProbe.managerApp),
                ("manager-executable", DriverProbe.managerExecutable),
                ("support-dir", DriverProbe.supportDirectory),
                ("package-version", DriverPackage.version),
                ("extension-version", DriverPackage.extensionVersion),
                ("package-url", DriverPackage.url),
                ("package-sha256", DriverPackage.sha256),
                // The whole verdict vocabulary on one line, in the enum's own order, so a
                // word added or dropped here reaches every reader that quotes the list.
                ("verdicts", DriverState.allCases.map(\.rawValue).joined(separator: " ")),
            ]
            print(pins.map { "\($0)\t\($1)" }.joined(separator: "\n"))
        }
    }
}

extension DriverCommand {
    /// One installer receipt, by package id.
    ///
    /// Removal asks this twice and about two different products: whether
    /// Karabiner-Elements is installed, because it shares both payload trees and
    /// removal could not put back what it deleted, and whether our own receipt is still
    /// held, because the package's uninstall scripts never call `pkgutil --forget`.
    ///
    /// [CLI] Three answers, told apart: the version on stdout, nothing on stdout for a
    /// Mac holding no such receipt, and exit 1 for a pkgutil that could not be read. A
    /// verb that collapsed the last two would let removal delete files on the strength
    /// of a reading nobody took. [LAW:no-silent-failure]
    struct Receipt: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "receipt",
            abstract: "Print the version of one installer receipt, or nothing when this Mac holds none."
        )

        @Argument(help: "The package id, e.g. org.pqrs.Karabiner-Elements.")
        var packageID: String

        func run() throws {
            do {
                // The empty line is deliberate: a caller reading this into a variable gets
                // an empty string for "no receipt" and never an unterminated stream.
                print(try DriverProbe.receiptVersion(of: packageID) ?? "")
            } catch {
                FileHandle.standardError.write(Data("lowtalker driver: \(error)\n".utf8))
                throw ExitCode(1)
            }
        }
    }
}
