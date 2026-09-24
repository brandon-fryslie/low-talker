import Foundation
import Testing
@testable import DriverExtension

/// What installing and removing decide, asserted against every reading that decides it.
///
/// Nothing here touches the machine's driver: the decisions are pure functions of a
/// reading, and the one effect exercised - landing a package in scratch - is pointed at a
/// directory of the suite's own and handed bytes that are not the pin, so nothing reaches
/// the installer. Installing the pinned bytes is checked live, and README.md records it.
/// [LAW:behavior-not-structure]
@Suite struct DriverInstallTests {
    // MARK: - how an install ends

    @Test(arguments: DriverState.allCases)
    func anInstallEndsByTheStateItLeft(state: DriverState) {
        let ending = try? DriverInstall.installed(state)
        switch state {
        case .enabled, .running:
            #expect(ending == .done("the driver is active."))
        case .awaitingApproval, .disabled:
            guard case .waitingOnAPerson(let said) = ending else { Issue.record("\(state) is not a wait on a person"); return }
            #expect(said.contains("Login Items & Extensions"))
            #expect(said.contains(DriverProbe.bundleID))
        // Every other state is one installing cannot leave behind, and says so rather
        // than reporting success with a caveat.
        case .absent, .installedInactive, .pendingReboot, .residue, .unknown:
            #expect(throws: DriverInstallRefusal.self) { try DriverInstall.installed(state) }
        }
    }

    // MARK: - how a removal ends

    /// The two states removal can end in, and nothing else: a Mac at either is where a
    /// second `remove` stops at once, and a Mac anywhere else after removal is a refusal.
    @Test(arguments: DriverState.allCases)
    func onlyAbsentAndPendingRebootEndARemoval(state: DriverState) {
        let ending = DriverInstall.removed(state)
        switch state {
        case .absent: #expect(ending == .done("the driver is gone."))
        case .pendingReboot:
            guard case .waitingOnAPerson(let said) = ending else { Issue.record("pending-reboot is not a wait"); return }
            #expect(said.contains("Restart the Mac"))
        default: #expect(ending == nil, "\(state.rawValue)")
        }
    }

    // MARK: - Karabiner-Elements

    /// Install only ever speaks about Karabiner-Elements; removal refuses on it. "Could not
    /// tell" is said as that on both sides and never read as absent.
    @Test func karabinerElementsWarnsAnInstallAndStopsARemoval() {
        #expect(DriverInstall.warning(about: .absent) == nil)
        #expect(DriverInstall.blocker(.absent) == nil)

        let installed = ElementsReceipt.installed(version: "15.5.0")
        #expect(DriverInstall.warning(about: installed)?.contains("Karabiner-Elements 15.5.0 is installed") == true)
        #expect(DriverInstall.warning(about: installed)?.contains(DriverProbe.supportDirectory) == true)
        #expect(DriverInstall.blocker(installed)?.description.contains("Karabiner-Elements 15.5.0 is installed") == true)

        let unreadable = ElementsReceipt.unreadable(reason: "pkgutil exited 1")
        #expect(DriverInstall.warning(about: unreadable)?.contains("could not tell whether \(DriverProbe.elementsReceiptID) is installed") == true)
        #expect(DriverInstall.blocker(unreadable)?.description.contains("refusing to guess") == true)
    }

    // MARK: - the withdrawal

    /// Only a live registration needs the Manager, and after the Manager has run only a
    /// retired one lets the files go: deleting the Manager under a live registration
    /// strands it with nothing able to retract it.
    @Test(arguments: Registration.allCases)
    func theManagerIsKeptUntilTheRegistrationIsRetired(registration: Registration) {
        let retired = registration == .unregistered || registration == .pendingReboot
        #expect(DriverInstall.needsWithdrawal(registration) == !retired)
        if retired {
            #expect(throws: Never.self) { try DriverInstall.confirmWithdrawn(registration) }
        } else {
            #expect(throws: DriverInstallRefusal.self) { try DriverInstall.confirmWithdrawn(registration) }
        }
    }

    // MARK: - no package is installed unjudged

    private func scratchRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "DriverInstallTests-\(UUID().uuidString)")
    }

    @Test func bytesThatAreNotThePinAreRefusedByName() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let impostor = root.appending(path: "impostor.pkg")
        try Data("not the pinned package\n".utf8).write(to: impostor)
        #expect(throws: DriverInstallRefusal("the impostor does not match the checksum pinned for \(DriverPackage.version)")) {
            try DriverPackage.verify(impostor, as: "the impostor")
        }
        // A path with nothing at it is its own refusal, not a checksum that failed.
        #expect(throws: DriverInstallRefusal("the absentee is not there, or is not a file")) {
            try DriverPackage.verify(root.appending(path: "absent.pkg"), as: "the absentee")
        }
    }

    /// A carried package is judged only after it is copied into a run directory of this
    /// program's own, so the bytes judged are the bytes installed; the scratch directory is
    /// narrowed to its owner first, and a refused run leaves nothing behind.
    @Test func aCarriedPackageIsCopiedInJudgedAndCleanedUp() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let impostor = root.appending(path: "impostor.pkg")
        try Data("not the pinned package\n".utf8).write(to: impostor)
        let scratch = root.appending(path: "scratch")

        var reachedTheInstaller = false
        #expect(throws: DriverInstallRefusal("the package at \(impostor.path) does not match the checksum pinned for \(DriverPackage.version)")) {
            try DriverInstall.withPackage(from: impostor, scratch: scratch) { _ in reachedTheInstaller = true }
        }
        #expect(!reachedTheInstaller)
        let mode = try FileManager.default.attributesOfItem(atPath: scratch.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)

        #expect(throws: DriverInstallRefusal("there is no package at \(root.appending(path: "absent.pkg").path), or it is not a file")) {
            try DriverInstall.withPackage(from: root.appending(path: "absent.pkg"), scratch: scratch) { _ in }
        }
        // A directory is not a flat package, and is refused before anything is copied.
        #expect(throws: DriverInstallRefusal("there is no package at \(root.path), or it is not a file")) {
            try DriverInstall.withPackage(from: root, scratch: scratch) { _ in }
        }
    }

    /// A carried package reached through a link lands as bytes, so the file judged is a file
    /// of this program's own and not an entry pointing at someone else's.
    @Test func aLinkedPackageLandsAsBytesNotAsTheLink() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appending(path: "target.pkg")
        try Data("not the pinned package\n".utf8).write(to: target)
        let link = root.appending(path: "link.pkg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let landed = root.appending(path: "landed.pkg")
        try DriverInstall.land(link, at: landed)
        try Data("rewritten after the check\n".utf8).write(to: target)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: landed.path)) == nil)
        #expect(try Data(contentsOf: landed) == Data("not the pinned package\n".utf8))
    }

    @Test func rootIsRefusedAndEveryoneElseIsNot() {
        #expect(throws: DriverInstallRefusal.self) { try DriverInstall.refuseRoot(0) }
        #expect(throws: Never.self) { try DriverInstall.refuseRoot(501) }
    }

    /// A command performed in front of the person stays in this process's group, which is
    /// what lets sudo ask for a password on the terminal and Ctrl-C reach it; its exit
    /// status comes back as the shell would report it.
    @Test func aPerformedCommandSharesOurProcessGroupAndReportsItsStatus() throws {
        #expect(try Command("/bin/sh", "-c", "exit 3").perform() == 3)
        let ours = getpgrp()
        #expect(try Command("/bin/sh", "-c", "[ \"$(ps -o pgid= -p $$ | tr -d ' ')\" = \"\(ours)\" ]").perform() == 0)
    }

    /// The URL is built from the version and the file name, so a bump cannot leave it
    /// aimed at the old release. [LAW:one-source-of-truth]
    @Test func thePackageUrlCarriesTheVersionItPins() {
        #expect(DriverPackage.url.contains("/v\(DriverPackage.version)/"))
        #expect(DriverPackage.url.hasSuffix("/\(DriverPackage.fileName)"))
        #expect(DriverPackage.fileName.hasSuffix("-\(DriverPackage.version).pkg"))
    }
}
