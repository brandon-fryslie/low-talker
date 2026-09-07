import Foundation

/// Reading this Mac for the four facts `DriverState` is derived from.
///
/// [LAW:effects-at-boundaries] Every command this program runs against the machine's
/// driver state runs here, and nothing here decides anything: the verdict is
/// `DriverState.init(_:)`, a pure function of what these return. That split is what
/// lets the table be tested against every combination of readings on a Mac that has
/// only one.
public enum DriverProbe {
    /// The driver extension's bundle id, and the team that signs it. macOS keys both the
    /// registration and the user's approval to this pair, which is why they identify the
    /// extension everywhere rather than the package or the app around it.
    public static let bundleID = "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice"
    public static let teamID = "G43BCU2T37"
    /// The IORegistry node the driver publishes once it has matched.
    public static let ioNodeName = "org_pqrs_Karabiner_DriverKit_VirtualHIDDeviceRoot"
    /// Karabiner-Elements is a separate product that ships this same driver and writes
    /// its own receipt beside ours. It shares both payload paths below, so removal has
    /// to ask about it before deleting anything.
    public static let elementsReceiptID = "org.pqrs.Karabiner-Elements"

    /// The package's two payload trees. Public because `scripts/virtual-hid-driver`
    /// deletes exactly these, and detection and deletion disagreeing about where the
    /// package lives is the one mistake removal cannot walk back.
    public static let managerApp = "/Applications/.Karabiner-VirtualHIDDevice-Manager.app"
    public static let supportDirectory = "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice"

    /// Every reading, taken now.
    ///
    /// Throws rather than returning a state meaning "I could not look". The bash this
    /// replaces spelled an unreadable machine as the `unknown` verdict, which put a
    /// failed reading and a genuinely unnameable registration into one word that no
    /// caller could pull back apart. [LAW:no-silent-failure]
    public static func facts() throws -> DriverFacts {
        DriverFacts(
            payload: try payload(),
            receipt: try receiptVersion(of: bundleID),
            registration: try registration(),
            ioNode: try ioNodePresent()
        )
    }

    /// Which of the package's two payload trees are on disk.
    static func payload() throws -> Payload {
        let present = [managerApp, supportDirectory].filter { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        }
        switch present.count {
        case 0: return .none
        case 2: return .both
        default: return .partial
        }
    }

    /// The version of one installer receipt, or nil when this Mac holds none.
    ///
    /// The id is a parameter because two products leave receipts this program cares
    /// about and reading them differs in nothing else. [LAW:one-type-per-behavior]
    public static func receiptVersion(of id: String) throws -> String? {
        try receiptVersion(of: id, from: Command("/usr/sbin/pkgutil", "--pkg-info", id).run())
    }

    /// What pkgutil said, read. Pure, so the three answers it can give - a version, no
    /// such receipt, and a pkgutil that could not run - are all reachable in a test on a
    /// Mac that can only produce one of them. [LAW:effects-at-boundaries]
    static func receiptVersion(of id: String, from read: Command.Output) throws -> String? {
        let named = "pkgutil --pkg-info \(id)"
        // pkgutil exits non-zero for two unrelated reasons: this Mac holds no such
        // receipt, which is a normal answer, and pkgutil could not run, which is not.
        // Sending both down the "no receipt" path is how a broken probe would come to
        // read as a clean machine. [LAW:no-silent-failure]
        guard read.status == 0 else {
            guard read.merged.contains("No receipt for") else {
                throw DriverUnreadable.toolFailed(tool: named, status: read.status, complaint: read.merged)
            }
            return nil
        }
        // Exit 0 with no version line is pkgutil saying something this build does not
        // understand, not a receipt-free Mac: the two answers stay apart.
        guard let version = read.stdout.lineValue(after: "version: ") else {
            throw DriverUnreadable.toolFailed(tool: named, status: 0, complaint: "no 'version:' line in: \(read.stdout)")
        }
        return version
    }

    /// The driver extension's registration with macOS. Public because removal reasons
    /// about this one fact by itself: only a live registration needs withdrawing, and
    /// only the withdrawal needs the Manager app that removal is about to delete.
    public static func registration() throws -> Registration {
        let listed = try Command("/usr/bin/systemextensionsctl", "list").run()
        guard listed.status == 0 else {
            throw DriverUnreadable.toolFailed(tool: "systemextensionsctl list", status: listed.status, complaint: listed.merged)
        }
        return try registration(inListing: listed.stdout)
    }

    /// The registration read out of a `systemextensionsctl list` listing. Pure, because
    /// the states worth checking - waiting for the user, two live registrations, an
    /// upgrade still pending a reboot - are states this Mac cannot be put into on demand.
    /// [LAW:effects-at-boundaries]
    static func registration(inListing listing: String) throws -> Registration {
        // The team id and bundle id together, positioned as columns rather than as loose
        // text: a bundle id quoted inside some other extension's name would match a bare
        // search and be read as this driver.
        let marker = "\t\(teamID)\t\(bundleID) ("
        let ours = listing.split(separator: "\n").filter { $0.contains(marker) }
        guard !ours.isEmpty else { return .unregistered }

        // A line naming this bundle that carries no bracketed state is a listing this
        // build cannot read, and it is refused rather than dropped. The bash this
        // replaces dropped such lines silently, which could turn two registrations into
        // one and hand back a confident verdict derived from half a reading.
        // [LAW:no-silent-failure]
        let states = try ours.map { line -> String in
            guard let state = line.bracketedSuffix else {
                throw DriverUnreadable.unbracketedListing(line: String(line))
            }
            return state
        }
        // A Mac upgraded but not yet restarted lists the bundle twice: the incoming
        // registration, and the outgoing one still waiting on a reboot. The outgoing
        // entry governs nothing, so what remains after dropping it is the answer.
        let live = states.filter { $0 != "terminated waiting to uninstall on reboot" }
        switch live.count {
        case 0: return .pendingReboot
        case 1: return Registration(bracketText: live[0])
        default: return .ambiguous
        }
    }

    /// Whether the driver has published its node in the IORegistry.
    static func ioNodePresent() throws -> Bool {
        let read = try Command("/usr/sbin/ioreg", "-r", "-n", ioNodeName, "-d", "1").run()
        guard read.status == 0 else {
            throw DriverUnreadable.toolFailed(tool: "ioreg -n \(ioNodeName)", status: read.status, complaint: read.merged)
        }
        return !read.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Why a reading of the machine could not be taken. Never a driver state: "I could not
/// look" and "the driver is in this state" are different facts, and a caller that
/// cannot tell them apart will report one as the other. [LAW:no-silent-failure]
public enum DriverUnreadable: Error, CustomStringConvertible, Equatable {
    case toolFailed(tool: String, status: Int32, complaint: String)
    case unbracketedListing(line: String)

    public var description: String {
        switch self {
        case .toolFailed(let tool, let status, let complaint):
            "could not read the machine: `\(tool)` exited \(status)\(complaint.isEmpty ? "" : ": \(complaint)")"
        case .unbracketedListing(let line):
            "systemextensionsctl listed the driver on a line carrying no bracketed state: \(line)"
        }
    }
}

private extension String {
    /// The remainder of the first line starting with `prefix`.
    func lineValue(after prefix: String) -> String? {
        split(separator: "\n").first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}

private extension StringProtocol {
    /// The text inside a trailing `[...]`, which is where `systemextensionsctl` puts the
    /// state. Anchored to the end of the line and taken from the last `[`, so a name
    /// containing brackets cannot be mistaken for the state.
    var bracketedSuffix: String? {
        guard hasSuffix("]"), let open = lastIndex(of: "[") else { return nil }
        return String(self[index(after: open)..<index(before: endIndex)])
    }
}
