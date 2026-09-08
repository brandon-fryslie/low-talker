import ArgumentParser
import DriverExtension
import Foundation

/// Where the virtual keyboard's driver extension stands on this Mac, read out loud.
///
/// `scripts/virtual-hid-driver` installs and removes the driver and calls these to find
/// out what it is looking at. The probe lives in Swift rather than in that script
/// because the menu-bar app has to reach the same answer in the same words, and an app
/// in /Applications cannot run a script out of this repo. [LAW:one-source-of-truth]
struct DriverCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "driver",
        abstract: "Read where the virtual keyboard's driver extension stands on this Mac.",
        subcommands: [State.self, Registered.self, Receipt.self, Pins.self]
    )
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
            abstract: "Print the four readings to stderr and one verdict word to stdout.",
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
    /// [LAW:one-source-of-truth] `scripts/virtual-hid-driver` and README.md both name
    /// some of these - the script because it deletes those paths and forgets that
    /// receipt, README because a reader follows the runbook by hand. Neither can read a
    /// Swift constant, so both keep copies and `make check-docs` reads this to prove the
    /// copies still agree. The value is here; the copies are derived and checked.
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
                // The binary onboarding names to a reader with no clone, so that the
                // activation step and the script's own `MANAGER` cannot drift apart.
                ("manager-executable", DriverProbe.managerExecutable),
                ("support-dir", DriverProbe.supportDirectory),
                // What onboarding names to a reader with no clone. The script fetches and
                // checksums the package and so holds the pin it acts on; this copy is the
                // one the app reads out loud, and check-docs proves they still agree.
                ("package-version", DriverPackage.version),
                ("package-url", DriverPackage.url),
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
