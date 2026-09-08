import Testing
@testable import DriverExtension

/// The two readings that involve real parsing, against the text the tools actually
/// print. Both are exercised through the pure half of the probe, so the states worth
/// checking - waiting for the user, an upgrade pending a reboot, two live registrations,
/// a pkgutil that could not run - are reachable on a Mac that is in none of them.
@Suite struct DriverProbeTests {
    /// A `systemextensionsctl list` listing carrying the header rows, an unrelated
    /// extension, and one line for our driver in whatever state is asked for.
    static func listing(driverLines: [String]) -> String {
        ([
            "14 extension(s)",
            "--- com.apple.system_extension.driver_extension (Go to 'System Settings > ...')",
            "enabled\tactive\tteamID\tbundleID (version)\tname\t[state]",
            "\t*\tQED4VVPZWA\tcom.logi.ghub.hidfilter (1.1.19/1.1.19)\tLogitech\t[activated disabled]",
        ] + driverLines).joined(separator: "\n")
    }

    /// One line for our driver, as macOS prints it.
    static func driverLine(
        team: String = DriverProbe.teamID,
        bundle: String = DriverProbe.bundleID,
        state: String? = "activated enabled"
    ) -> String {
        let head = "*\t*\t\(team)\t\(bundle) (1.8.0/1.8.0)\t\(bundle)"
        return state.map { "\(head)\t[\($0)]" } ?? head
    }

    @Test func theListingThisMacPrintsReadsAsEnabled() throws {
        #expect(try DriverProbe.registration(inListing: Self.listing(driverLines: [Self.driverLine()])) == .enabled)
    }

    @Test func everyBracketTextMacOSPrintsHasAWordOfItsOwn() throws {
        let expected: [String: Registration] = [
            "activated enabled": .enabled,
            "activated disabled": .disabled,
            "activated waiting for user": .waiting,
            "terminated waiting to uninstall on reboot": .pendingReboot,
        ]
        for (text, want) in expected {
            #expect(try DriverProbe.registration(inListing: Self.listing(driverLines: [Self.driverLine(state: text)])) == want)
        }
    }

    /// Bracket text this build has never seen becomes `unknown` and not the nearest
    /// familiar word: misfiling an unseen state is how removal comes to report success on
    /// a machine it did not understand. [LAW:no-silent-failure]
    @Test func bracketTextThisBuildCannotNameIsUnknownRatherThanTheNearestWord() throws {
        let listing = Self.listing(driverLines: [Self.driverLine(state: "activated pending something new")])
        #expect(try DriverProbe.registration(inListing: listing) == .unknown)
    }

    @Test func aListingWithoutOurDriverIsUnregistered() throws {
        #expect(try DriverProbe.registration(inListing: Self.listing(driverLines: [])) == .unregistered)
    }

    /// The team id and the bundle id are matched as adjacent columns. A different team
    /// shipping a bundle by our id is a different extension, and reading its state as
    /// ours would report a driver this Mac does not have.
    @Test func anotherTeamsExtensionOfTheSameNameIsNotOurs() throws {
        let listing = Self.listing(driverLines: [Self.driverLine(team: "ZZZZZZZZZZ")])
        #expect(try DriverProbe.registration(inListing: listing) == .unregistered)
    }

    /// Our bundle id quoted inside another extension's name column is text, not a
    /// registration. The marker carries the tabs around it for exactly this.
    @Test func ourBundleIdInsideAnotherExtensionsNameIsNotARegistration() throws {
        let imposter = "\t*\tZZZZZZZZZZ\tcom.example.thing (1/1)\twraps \(DriverProbe.bundleID) (nicely)\t[activated enabled]"
        #expect(try DriverProbe.registration(inListing: Self.listing(driverLines: [imposter])) == .unregistered)
    }

    /// Removal leaves this behind until the Mac restarts, and it is the whole reason
    /// `pending-reboot` is a state rather than a failure.
    @Test func anExtensionOnlyWaitingToUninstallIsPendingReboot() throws {
        let listing = Self.listing(driverLines: [Self.driverLine(state: "terminated waiting to uninstall on reboot")])
        #expect(try DriverProbe.registration(inListing: listing) == .pendingReboot)
    }

    /// The upgrade window: the incoming registration and the outgoing one listed at once.
    /// The outgoing entry governs nothing, so the incoming one is the answer.
    @Test func anUpgradeStillAwaitingARebootReadsAsItsIncomingRegistration() throws {
        let listing = Self.listing(driverLines: [
            Self.driverLine(state: "terminated waiting to uninstall on reboot"),
            Self.driverLine(state: "activated enabled"),
        ])
        #expect(try DriverProbe.registration(inListing: listing) == .enabled)
    }

    @Test func twoLiveRegistrationsForOneBundleAreAmbiguous() throws {
        let listing = Self.listing(driverLines: [Self.driverLine(state: "activated enabled"), Self.driverLine(state: "activated disabled")])
        #expect(try DriverProbe.registration(inListing: listing) == .ambiguous)
    }

    /// A line naming our driver but carrying no bracketed state is a listing this build
    /// cannot read, and it is refused. Dropping it instead would turn two registrations
    /// into one and hand back a confident verdict derived from half a reading.
    @Test func aLineNamingOurDriverWithNoBracketedStateIsRefused() {
        let listing = Self.listing(driverLines: [Self.driverLine(state: nil)])
        #expect(throws: DriverUnreadable.unbracketedListing(line: Self.driverLine(state: nil))) {
            try DriverProbe.registration(inListing: listing)
        }
    }

    // MARK: - the installer receipt

    @Test func pkgutilsReportOfAHeldReceiptIsItsVersion() throws {
        let said = Command.Output(status: 0, stdout: "package-id: x\nversion: 8.4.0\nvolume: /\n", stderr: "")
        #expect(try DriverProbe.receiptVersion(of: "x", from: said) == "8.4.0")
    }

    /// A Mac holding no such receipt is a normal answer, and the only one that may come
    /// back as "no receipt".
    @Test func aMacHoldingNoSuchReceiptReadsAsNoReceipt() throws {
        let said = Command.Output(status: 1, stdout: "", stderr: "No receipt for 'x' found at '/'.")
        #expect(try DriverProbe.receiptVersion(of: "x", from: said) == nil)
    }

    /// A pkgutil that could not run is not a clean Mac, and the two must not arrive as
    /// one answer. [LAW:no-silent-failure]
    @Test func aPkgutilThatCouldNotRunIsRefusedRatherThanReadAsACleanMac() {
        let said = Command.Output(status: 70, stdout: "", stderr: "unable to open receipt database")
        #expect(throws: DriverUnreadable.self) { try DriverProbe.receiptVersion(of: "x", from: said) }
    }

    /// Exit 0 with nothing this build recognises is pkgutil saying something unread, not
    /// a receipt-free Mac.
    @Test func pkgutilSucceedingWithNoVersionLineIsRefused() {
        let said = Command.Output(status: 0, stdout: "package-id: x\n", stderr: "")
        #expect(throws: DriverUnreadable.self) { try DriverProbe.receiptVersion(of: "x", from: said) }
    }
}
