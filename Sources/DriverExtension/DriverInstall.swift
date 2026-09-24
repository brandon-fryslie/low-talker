import Darwin
import Foundation

/// Putting the driver on this Mac and taking it off, from the public pqrs-org package
/// alone. Karabiner-Elements is never involved and is never a requirement.
///
/// Here rather than in a script beside the repo because the app carries the CLI and not
/// the repo: a Mac with no clone reaches these verbs through the same binary that reads
/// the driver's state, and the paths removal deletes are the constants `DriverProbe`
/// detects by, not copies handed across a process boundary. [LAW:one-source-of-truth]
///
/// Run as the console user, not under sudo: the Manager has to be the logged-in user,
/// because macOS attributes the activation request to whoever asks and the approval the
/// user gives answers that request. The file steps take sudo themselves.
///
/// [LAW:effects-at-boundaries] Every decision is a pure function of a reading, below the
/// effects that take the readings, so each is exercised against states this Mac cannot be
/// put into.
public enum DriverInstall {
    /// How a verb that did its part ends: finished, or waiting on something only a person
    /// can do. A verb that could not do its part throws `DriverInstallRefusal` instead.
    public enum Ending: Equatable, Sendable {
        case done(String)
        case waitingOnAPerson(String)
    }

    /// Where a package lands, downloaded or copied: one fixed directory under this user's
    /// temporary area, proven ours before use, holding one directory per run.
    public static let scratch = FileManager.default.temporaryDirectory.appending(path: "low-talker-virtual-hid-driver")

    // MARK: - the verbs

    /// Downloads the pinned package, or takes the one at `source` - which is how a release's
    /// own copy is installed with the network off - verifies it, installs it, and asks
    /// macOS to activate the driver.
    public static func install(from source: URL?, scratch: URL = scratch) throws -> Ending {
        try refuseRoot(getuid())
        if let warning = warning(about: try DriverProbe.facts().elementsReceipt) { say(warning) }
        try withPackage(from: source, scratch: scratch) { package in
            say("==> installing (sudo)")
            try require(Command("/usr/bin/sudo", "/usr/sbin/installer", "-pkg", package.url.path, "-target", "/"), "the installer")
        }
        // The Manager does not return while macOS waits for the approval, so what it waits
        // on is said before it starts: a person at the screen, or an agent reading this
        // over ssh, learns the click it needs from here and not from a silent hang.
        // Measured on studious.local, a Mac that had never approved the driver: the
        // Manager sat in `activate` for as long as nobody clicked.
        say("""
            ==> activating the driver extension. On a Mac that has not approved this driver,
                this waits until you turn it on: \(approval)
            """)
        try require(Command(DriverProbe.managerExecutable, "activate"), "the Manager's activation")
        // The Manager exits 0 even when handed a bare usage error, so its exit status proves
        // little and the state reading is the only honest report. [LAW:verifiable-goals]
        return try installed(reported(DriverProbe.facts()))
    }

    /// The verified package, copied into `directory` under its release name, for a release
    /// to carry. Returns the copy.
    public static func fetch(into directory: URL, scratch: URL = scratch) throws -> URL {
        try withPackage(from: nil, scratch: scratch) { package in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appending(path: DriverPackage.fileName)
            if FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.removeItem(at: copy) }
            try FileManager.default.copyItem(at: package.url, to: copy)
            return copy
        }
    }

    /// Deactivates the extension, deletes both payload trees, and forgets the receipt.
    public static func remove() throws -> Ending {
        try refuseRoot(getuid())
        // One reading answers the first three questions: where removal stands, whether
        // Karabiner-Elements shares the files, and whether the extension is registered.
        // A machine already at the end of removal has nothing left to withdraw, and the
        // Manager that would do the withdrawing is the thing removal deletes, so a second
        // `remove` says where the machine actually stands.
        let before = try reading({ try DriverProbe.facts() },
            or: "could not read where the driver stands, and removal deletes what nothing here could put back; refusing to guess")
        if let ending = removed(DriverState(before)) { return ending }

        if let blocker = blocker(before.elementsReceipt) { throw blocker }

        // [LAW:no-ambient-temporal-coupling] Deactivation must precede file removal, and the
        // order is not a preference. Only the Manager can withdraw the extension, and
        // removing the files deletes the Manager; the other way round strands the
        // registration with nothing left on the machine able to retract it.
        let registered = before.registration
        if needsWithdrawal(registered) {
            say("==> deactivating the driver extension")
            guard FileManager.default.isExecutableFile(atPath: DriverProbe.managerExecutable) else {
                throw DriverInstallRefusal("the extension is registered as '\(registered.rawValue)' but \(DriverProbe.managerExecutable) is missing, so nothing here can withdraw it; reinstall the package, then run 'remove'")
            }
            try require(Command(DriverProbe.managerExecutable, "deactivate"), "the Manager's deactivation")
            // The Manager prints "request ... is failed" and still exits 0, so the withdrawal
            // is confirmed against the registration itself.
            try confirmWithdrawn(try reading(DriverProbe.registration,
                or: "could not confirm the extension was withdrawn because its registration could not be read; refusing to delete the Manager that is the only thing able to withdraw it"))
        }

        say("==> removing files (sudo)")
        try require(Command("/usr/bin/sudo", "/bin/rm", "-rf", DriverProbe.managerApp, DriverProbe.supportDirectory), "removing the files")

        // What the package's own uninstall scripts leave behind: they never call
        // `pkgutil --forget`, which fails on a receipt that is not there.
        let receipt = try reading({ try DriverProbe.receiptVersion(of: DriverProbe.bundleID) },
            or: "the installer receipt for \(DriverProbe.bundleID) could not be read, so whether to forget it is unknown; the payload is already deleted, and running 'remove' again once the cause is fixed will finish the job")
        if receipt != nil {
            say("==> forgetting installer receipt \(DriverProbe.bundleID) (sudo)")
            try require(Command("/usr/bin/sudo", "/usr/sbin/pkgutil", "--forget", DriverProbe.bundleID), "forgetting the receipt")
        }

        let after = reported(try DriverProbe.facts())
        guard let ending = removed(after) else {
            throw DriverInstallRefusal("after removal, the driver is '\(after.rawValue)', which is not a state removing can leave behind")
        }
        return ending
    }

    // MARK: - the decisions

    /// The click macOS waits for, said once for both places that say it.
    static let approval = """
        open System Settings > General > Login Items & Extensions, click the (i) beside \
        Driver Extensions, turn on \(DriverProbe.bundleID), and authenticate when macOS asks.
        """

    /// What `install` says about Karabiner-Elements before it touches anything. It only ever
    /// speaks: installing replaces the shared Manager app and support directory rather than
    /// deleting them, so a Mac holding Karabiner-Elements can still run the driver, and
    /// refusing would strand it. A receipt nobody could read is said out loud as that.
    static func warning(about elements: ElementsReceipt) -> String? {
        let shared = "\(DriverProbe.managerApp) and \(DriverProbe.supportDirectory)"
        let continuing = "Continuing, because installing replaces those files and deletes nothing."
        return switch elements {
        case .absent: nil
        case .unreadable:
            "warning: could not tell whether \(DriverProbe.elementsReceiptID) is installed; if it is, this replaces \(shared), which it also owns. \(continuing)"
        case .installed(let version):
            "warning: Karabiner-Elements \(version) is installed and also owns \(shared); this replaces them with package \(DriverPackage.version). \(continuing)"
        }
    }

    /// How an install ends, read off the state it left.
    static func installed(_ state: DriverState) throws -> Ending {
        switch state {
        case .enabled, .running:
            return .done("the driver is active.")
        case .awaitingApproval, .disabled:
            return .waitingOnAPerson("""
                the driver is installed and waiting for you: \(approval)
                Then confirm with:  lowtalker driver expect enabled
                """)
        // The package is on disk but macOS holds no registration for it, so the request
        // never landed - whether the Manager refused it or the listing has not caught up.
        case .installedInactive:
            throw DriverInstallRefusal("the package installed but macOS holds no registration for \(DriverProbe.bundleID), so the activation request did not take; run 'install' again")
        case .absent, .pendingReboot, .residue, .unknown:
            throw DriverInstallRefusal("after installing, the driver is '\(state.rawValue)', which is not a state installing can leave behind")
        }
    }

    /// The two states removal can end in, as endings; nil for every other state. Shared by
    /// the early return and the closing report, so the two cannot describe one state
    /// differently. [LAW:one-source-of-truth]
    static func removed(_ state: DriverState) -> Ending? {
        switch state {
        case .absent:
            .done("the driver is gone.")
        case .pendingReboot:
            .waitingOnAPerson("""
                the files and the receipt are gone, but macOS keeps the
                extension registered as "terminated waiting to uninstall on reboot" until the
                machine restarts. That entry is not a failure, and nothing else clears it.

                  Restart the Mac

                Then confirm with:  lowtalker driver expect absent
                """)
        case .installedInactive, .awaitingApproval, .disabled, .enabled, .running, .residue, .unknown:
            nil
        }
    }

    /// Karabiner-Elements ships this same driver and shares the Manager app, the support
    /// directory and the receipt id, so removal would take it down with it. The refusal
    /// comes before the deactivation too, because withdrawing the extension already stops
    /// the driver Karabiner-Elements is using. "I could not tell" is not "it is not
    /// installed", and this is the one verb whose mistake cannot be walked back.
    static func blocker(_ elements: ElementsReceipt) -> DriverInstallRefusal? {
        switch elements {
        case .absent:
            nil
        case .unreadable:
            DriverInstallRefusal("could not tell whether \(DriverProbe.elementsReceiptID) is installed, and removal deletes files the two products share; refusing to guess")
        case .installed(let version):
            DriverInstallRefusal("Karabiner-Elements \(version) is installed and shares \(DriverProbe.managerApp) and \(DriverProbe.supportDirectory) with the driver package, so removing the driver would break it and nothing here could put it back; remove Karabiner-Elements first if that is what you want")
        }
    }

    /// Whether a registration needs withdrawing before the files go. An extension already
    /// retired has nothing to withdraw, which is what lets a `remove` interrupted after the
    /// files were deleted come back and finish the receipt.
    static func needsWithdrawal(_ registration: Registration) -> Bool {
        switch registration {
        case .unregistered, .pendingReboot: false
        case .enabled, .disabled, .waiting, .unknown, .ambiguous: true
        }
    }

    /// Deleting the files while the extension is still registered is the one ordering
    /// mistake removal can make, and it cannot be undone without reinstalling.
    ///
    /// The same question `needsWithdrawal` asks, asked again after the Manager ran, so the
    /// two can never classify a registration differently. [LAW:single-enforcer]
    static func confirmWithdrawn(_ registration: Registration) throws {
        guard !needsWithdrawal(registration) else {
            throw DriverInstallRefusal("the extension is still registered as '\(registration.rawValue)' after deactivation; refusing to delete the Manager that is the only thing able to withdraw it")
        }
    }

    /// Both verbs need the console user: macOS attributes the activation request to
    /// whoever asks, so a request made as root is one the person's approval never answers.
    static func refuseRoot(_ uid: uid_t) throws {
        guard uid != 0 else {
            throw DriverInstallRefusal("run this as yourself, not under sudo: macOS attributes the driver's activation to whoever asks, and your approval answers only your own request. It asks for your password itself for the file steps.")
        }
    }

    // MARK: - the effects

    /// The pinned package in a run directory of this program's own, verified there, for the
    /// length of `body`.
    ///
    /// The scratch directory is fixed and `sudo installer` re-reads the package after it
    /// was judged. Whoever held that directory could swap the bytes in that gap and be
    /// installed as root, so it is proven ours and narrowed before anything goes into it. A
    /// package taken from a release is copied in for the same reason rather than judged
    /// where it lies: whoever can write beside the app could swap it after the check. Each
    /// run gets a fresh directory, so a second run cannot replace the bytes this one judged
    /// while it waits at the sudo prompt. [LAW:no-ambient-temporal-coupling]
    static func withPackage<T>(from source: URL?, scratch: URL, _ body: (VerifiedPackage) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let owner = (try FileManager.default.attributesOfItem(atPath: scratch.path)[.ownerAccountID] as? NSNumber)?.uint32Value
        guard owner == getuid() else {
            throw DriverInstallRefusal("\(scratch.path) is owned by uid \(owner.map(String.init) ?? "unknown") and not by you, so nothing put into it can be trusted; remove it and run again")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.path)
        var template = Array(scratch.appending(path: "run.XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else {
            throw DriverInstallRefusal("could not make a run directory in \(scratch.path): \(String(cString: strerror(errno)))")
        }
        let run = URL(fileURLWithPath: String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), isDirectory: true)
        defer {
            do { try FileManager.default.removeItem(at: run) } catch { say("warning: could not remove \(run.path): \(error)") }
        }
        let landed = run.appending(path: "driver.pkg")
        let package: VerifiedPackage
        if let source {
            say("==> taking \(source.path)")
            try land(source, at: landed)
            package = try DriverPackage.verify(landed, as: "the package at \(source.path)")
        } else {
            say("==> downloading \(DriverPackage.url)")
            try require(Command("/usr/bin/curl", "--fail", "--show-error", "--silent", "--location", "--output", landed.path, DriverPackage.url), "the download")
            package = try DriverPackage.verify(landed, as: "the downloaded package")
        }
        return try body(package)
    }

    /// A carried package's bytes, written to `landed`. The bytes and never the entry: a link
    /// copied as a link would leave the file it points at - someone else's to rewrite - as
    /// the one `installer` reads after the check.
    static func land(_ source: URL, at landed: URL) throws {
        guard isFile(source) else { throw DriverInstallRefusal("there is no package at \(source.path), or it is not a file") }
        try Data(contentsOf: source).write(to: landed)
    }

    /// The readings behind a verdict, shown with it the way `lowtalker driver state` shows
    /// them, so an ending or a refusal can be checked against what it was derived from.
    private static func reported(_ facts: DriverFacts) -> DriverState {
        let state = DriverState(facts)
        say("\(facts)\nverdict            \(state.rawValue)")
        return state
    }

    /// A reading removal cannot act without, with the sentence that says what refusing to
    /// guess protects. "I could not look" never becomes an answer. [LAW:no-silent-failure]
    private static func reading<T>(_ read: () throws -> T, or refusal: String) throws -> T {
        do { return try read() } catch { throw DriverInstallRefusal("\(refusal) (\(error))") }
    }

    private static func require(_ command: Command, _ what: String) throws {
        let status = try command.perform()
        guard status == 0 else { throw DriverInstallRefusal("\(what) failed: `\(command.tool.path) \(command.arguments.joined(separator: " "))` exited \(status)") }
    }

    private static func say(_ line: String) {
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }
}
