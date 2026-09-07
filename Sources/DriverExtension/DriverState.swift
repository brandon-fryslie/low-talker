/// Where the Karabiner-DriverKit-VirtualHIDDevice driver extension stands on this Mac,
/// as one word, and the four readings that word is derived from.
///
/// [LAW:one-source-of-truth] This is the whole vocabulary for the driver's state, and
/// it exists once. `scripts/virtual-hid-driver` prints these words, the menu-bar app
/// shows them, `expect` asserts them and README.md documents them; a second spelling
/// anywhere is a way for two readers to come to different conclusions about one
/// machine. The probe used to live in bash, where the app - which cannot run a script
/// out of this repo - had no way to reach it.

/// Which of the installer package's two payload trees are on disk.
public enum Payload: String, Sendable, Hashable, CaseIterable {
    case none
    case partial
    case both
}

/// The driver extension's registration with macOS, parsed from the bracket text
/// `systemextensionsctl list` prints.
///
/// [LAW:parse-dont-validate] That text is read once, here, into a case the rest of the
/// program matches exactly. Nothing downstream greps the listing again, so nothing
/// downstream can read it differently.
///
/// The mapping is total: bracket text nobody here has seen becomes `unknown` rather
/// than the nearest familiar case. Misfiling an unseen state is how removal would come
/// to report success on a machine it did not understand. [LAW:no-silent-failure]
public enum Registration: String, Sendable, Hashable, CaseIterable {
    case unregistered
    case enabled
    case disabled
    case waiting
    case pendingReboot = "pending-reboot"
    /// Bracket text this build cannot name.
    case unknown
    /// Two live registrations for one bundle id at once.
    case ambiguous

    /// The bracket text macOS prints, as this program's own word.
    public init(bracketText: String) {
        switch bracketText {
        case "activated enabled": self = .enabled
        case "activated disabled": self = .disabled
        case "activated waiting for user": self = .waiting
        case "terminated waiting to uninstall on reboot": self = .pendingReboot
        default: self = .unknown
        }
    }
}

/// The four readings of the machine, and nothing else. The verdict below is a function
/// of exactly this and of no other input.
public struct DriverFacts: Sendable, Hashable {
    /// Which payload trees the package left on disk.
    public let payload: Payload
    /// The installer receipt's version, or nil when this Mac holds no such receipt. The
    /// receipt outlives the files: the package's own uninstall scripts never call
    /// `pkgutil --forget`.
    public let receipt: String?
    public let registration: Registration
    /// Whether the driver has matched and published its node in the IORegistry. This is
    /// loading, not enabling: the extension can be enabled and still absent here until
    /// some client opens it.
    public let ioNode: Bool

    public init(payload: Payload, receipt: String?, registration: Registration, ioNode: Bool) {
        self.payload = payload
        self.receipt = receipt
        self.registration = registration
        self.ioNode = ioNode
    }
}

extension DriverFacts: CustomStringConvertible {
    /// The fact table a reader gets on stderr, one line per reading. Every reading is
    /// printed every time, including the ones that agree with the verdict, because a
    /// verdict nobody can check against its inputs is a verdict nobody can debug.
    public var description: String {
        """
        payload on disk    \(payload.rawValue)
        installer receipt  \(receipt ?? "none")
        extension state    \(registration.rawValue)
        IORegistry node    \(ioNode ? "yes" : "no")
        """
    }
}

/// One word for the whole machine.
public enum DriverState: String, Sendable, Hashable, CaseIterable {
    /// Nothing of the package is on this Mac.
    case absent
    /// The package is installed but macOS holds no registration, so an activation
    /// request never landed.
    case installedInactive = "installed-inactive"
    /// Registered and waiting for the one click only the user can give.
    case awaitingApproval = "awaiting-approval"
    /// Registered and switched off.
    case disabled
    /// macOS has the extension switched on. Nothing is left for anyone to approve.
    case enabled
    /// Enabled, and the driver has published its node: the fully working state.
    case running
    /// The files and the receipt are gone; macOS keeps the registration until a restart.
    case pendingReboot = "pending-reboot"
    /// Some of the package is here and some is not, in a combination that is not one of
    /// the states install or remove can leave behind.
    case residue
    /// A registration this build cannot name, or two live ones at once. Kept apart from
    /// `residue` because residue is a mess we understand and this is not.
    case unknown

    /// The verdict, derived from the four facts and from nothing else.
    ///
    /// [LAW:dataflow-not-control-flow] Written as a table of whole keys rather than a
    /// chain of conditions, so it reads as something to check against a machine instead
    /// of something to simulate. The default arm is `residue`: a combination nobody
    /// listed is a mess, and saying so beats picking the nearest listed state.
    public init(_ facts: DriverFacts) {
        // The receipt's version does not change any verdict; only whether one is held
        // does. Collapsed here so the table's keys stay readable.
        switch (facts.payload, facts.receipt != nil, facts.registration, facts.ioNode) {
        case (_, _, .unknown, _), (_, _, .ambiguous, _): self = .unknown
        case (.none, false, .unregistered, false): self = .absent
        case (.both, true, .unregistered, false): self = .installedInactive
        case (.both, true, .waiting, false): self = .awaitingApproval
        case (.both, true, .disabled, false): self = .disabled
        case (.both, true, .enabled, false): self = .enabled
        case (.both, true, .enabled, true): self = .running
        // Removal finished. Spelled as a whole key rather than matched on the
        // registration alone: `remove` reads this verdict as "nothing left to do", and a
        // machine still holding a payload or a receipt is `residue`, not this.
        case (.none, false, .pendingReboot, false): self = .pendingReboot
        default: self = .residue
        }
    }
}
