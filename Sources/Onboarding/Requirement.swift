import DriverExtension

/// One thing that must hold before low-talker can type, as this Mac actually stands.
///
/// [LAW:one-type-per-behavior] Four very different facts - a driver extension's
/// registration, a launchd job's hold on a Mach service, an approval only a person can
/// give, a cached answer from a setup assistant - are one type with four instances,
/// because what a reader does with them does not differ: read what is there, and do the
/// step when there is one. Four requirement types would be four renderings of one shape.
public struct Requirement: Sendable, Hashable {
    /// What must hold, in the words the menu and the CLI both use.
    public let name: String
    /// What was read off this Mac. Shown whether or not there is a step, because a
    /// requirement that says only "not ready" is one nobody can act on or report.
    public let reads: String
    /// What is left for a person to do, and nil when nothing is. Genuinely absent rather
    /// than an empty string: "nothing to do" and "a step nobody wrote" are different
    /// facts, and a reader that cannot tell them apart will print the second as the
    /// first.
    public let step: String?

    public var met: Bool { step == nil }

    public init(name: String, reads: String, step: String?) {
        self.name = name
        self.reads = reads
        self.step = step
    }
}

public extension Requirement {
    /// A requirement whose fact could not be read.
    ///
    /// The row stays in the list rather than being dropped or skipped: every requirement
    /// is shown every time, and one that could not be read is never silently absent from
    /// a list a reader takes as complete. It carries a step, so it is never `met` and
    /// never lets `ready` come out true on the strength of a reading nobody took.
    /// [LAW:no-silent-failure]
    static func unreadable(_ name: String, _ error: any Error) -> Requirement {
        Requirement(name: name, reads: "could not be read", step: "\(error)")
    }
}

public extension Requirement {
    /// The step as the lines it was written in, and no lines at all when there is
    /// nothing to do. Split here so that the menu, which makes one item per line, and
    /// the CLI, which indents them, are working from one shape rather than each taking a
    /// string apart its own way. [LAW:one-source-of-truth]
    var stepLines: [String] { step.map { $0.components(separatedBy: "\n") } ?? [] }
}

extension Requirement: CustomStringConvertible {
    public var description: String {
        (["\(name): \(reads)"] + stepLines.map { "  \($0)" }).joined(separator: "\n")
    }
}

/// Where this Mac stands against everything low-talker needs, as one list.
///
/// This is what `lowtalker onboard` prints and what the menu-bar app shows. It is
/// computed rather than printed so a test can read it as a value, and so both surfaces
/// say the same words without either spelling them a second time.
/// [LAW:effects-at-boundaries]
public struct Readiness: Sendable, CustomStringConvertible {
    public let requirements: [Requirement]

    public init(_ requirements: [Requirement]) { self.requirements = requirements }

    /// Nothing is left for anyone to do.
    public var ready: Bool { requirements.allSatisfy(\.met) }

    /// Every requirement, every time, in a fixed order - the met ones included. A list
    /// that showed only what was wrong would leave a reader unable to tell "checked and
    /// fine" from "never checked". [LAW:dataflow-not-control-flow]
    public var description: String { requirements.map(\.description).joined(separator: "\n") }
}

// MARK: - the driver extension

/// Where the two approvals live. Named once because every step that asks for a click
/// ends up here, and a reader following one of them to a pane that does not exist is a
/// reader who stops.
private let loginItemsPane = "System Settings > General > Login Items & Extensions"

public extension Requirement {
    /// The driver extension low-talker types through.
    ///
    /// Every word `DriverState` can take gets its own step, because they are not degrees
    /// of one problem: a Mac with no package needs an install, a Mac holding a
    /// registration nobody approved needs a click, and a Mac mid-removal needs a
    /// restart. A single "the driver is not ready" would send all three the same way.
    static func driverExtension(_ state: DriverState) -> Requirement {
        Requirement(name: "Driver extension", reads: state.rawValue, step: step(for: state))
    }

    private static func step(for state: DriverState) -> String? {
        switch state {
        // macOS has the extension switched on. `running` additionally means some client
        // has opened it, which is not something a user does and not something to ask for.
        case .enabled, .running:
            nil
        case .absent:
            """
            The driver package is not on this Mac. Install it:
                scripts/virtual-hid-driver install
            """
        case .installedInactive:
            """
            The package is installed but macOS holds no registration for it,
            so the activation request never landed. Run it again:
                scripts/virtual-hid-driver install
            """
        case .awaitingApproval:
            """
            Open \(loginItemsPane),
            click the (i) beside Driver Extensions, and turn on
            \(DriverProbe.bundleID).
            Authenticate when macOS asks.
            """
        case .disabled:
            """
            The driver is registered and switched off. Open
            \(loginItemsPane),
            click the (i) beside Driver Extensions, and turn on
            \(DriverProbe.bundleID).
            """
        case .pendingReboot:
            """
            The driver was removed, and macOS keeps it registered until this
            Mac restarts. Restart the Mac.
            """
        case .residue:
            """
            Part of the driver package is here and part is not.
            Remove what is there, then install it again:
                scripts/virtual-hid-driver remove
                scripts/virtual-hid-driver install
            """
        // The probe said it could not read the machine, or read a registration it could
        // not name. Either way the reason is already on stderr, and pointing at it beats
        // inventing a step for a state nobody has identified. [LAW:no-silent-failure]
        case .unknown:
            """
            This Mac's driver state could not be read. This says what could
            not be read, and why:
                scripts/virtual-hid-driver state
            """
        }
    }
}

// MARK: - the keyboard helper

/// Where the root keyboard helper stands, as one word.
///
/// The reading comes from launchd, which is what both the app and the CLI can ask. The
/// app knows one thing launchd cannot say, and `awaitingApproval` is that thing: see
/// `sharpenedByTheAppsOwnRegistration`.
public enum HelperStanding: Sendable, Hashable {
    /// The app's job holds the Mach service: registered, approved, and answering.
    case holdingTheService
    /// A job under the app's label is loaded, and launchd gave the service to another
    /// claimant.
    ///
    /// launchd does not make the loser loud: the second job to ask for a Mach service
    /// name bootstraps with exit 0, runs, and simply never gets the endpoint. An app in
    /// this state reports its helper enabled and types nothing, which is the whole
    /// reason this is a requirement of its own and not folded into the approval.
    case anotherJobHoldsTheService
    /// launchd has no job under the app's label at all.
    case noJob
    /// Registered, and waiting for the one approval only a person can give.
    case awaitingApproval

    /// The launchd reading, sharpened by what only the app can ask.
    ///
    /// From outside, a helper that was never registered and one that is registered and
    /// waiting for its click look identical: launchd holds no job either way. Only the
    /// app can put the question to `SMAppService`, so only the app can tell them apart -
    /// and the two want opposite steps, one a launch and one a click.
    ///
    /// - Parameter approvalPending: what the app's own registration says, and nil from a
    ///   caller that has none to ask about. Nil rather than false, because "no, it is
    ///   not waiting" and "I could never have asked" send a reader to different steps,
    ///   and only one of them is true of a CLI. Total either way, so no caller has to
    ///   ask whether it is the one that can sharpen. [LAW:dataflow-not-control-flow]
    public func sharpenedByTheAppsOwnRegistration(approvalPending: Bool?) -> HelperStanding {
        self == .noJob && approvalPending == true ? .awaitingApproval : self
    }
}

public extension Requirement {
    /// The root helper that owns the virtual keyboard.
    static func keyboardHelper(_ standing: HelperStanding, serviceName: String, developmentLabel: String) -> Requirement {
        Requirement(name: "Keyboard helper", reads: reads(for: standing), step: step(for: standing, serviceName: serviceName, developmentLabel: developmentLabel))
    }

    private static func reads(for standing: HelperStanding) -> String {
        switch standing {
        case .holdingTheService: "answering"
        case .anotherJobHoldsTheService: "registered, but another job holds the service"
        case .noJob: "not registered"
        case .awaitingApproval: "waiting for approval in Login Items & Extensions"
        }
    }

    private static func step(for standing: HelperStanding, serviceName: String, developmentLabel: String) -> String? {
        switch standing {
        case .holdingTheService:
            nil
        case .awaitingApproval:
            """
            Open \(loginItemsPane)
            and turn on LowTalker. The helper is registered as a login item
            and waits there until you do.
            """
        case .noJob:
            """
            launchd holds no job for the helper. Launch LowTalker once - it
            registers on every launch - and turn it on in
            \(loginItemsPane) if it asks.
            """
        case .anotherJobHoldsTheService:
            """
            Another launchd job holds \(serviceName), so the app's
            helper never got the name and answers nothing, however healthy it
            looks. That job is \(developmentLabel), the
            development one. Remove it, then launch LowTalker again:
                scripts/keyboard-helper uninstall
            """
        }
    }
}

// MARK: - the Keyboard Setup Assistant

public extension Requirement {
    /// Whether Keyboard Setup Assistant already holds a verdict for this device.
    ///
    /// Not an approval, and the only one of the four that appears on first *use* rather
    /// than at install: the moment the virtual keyboard enumerates, macOS raises the
    /// assistant, it takes focus, and it asks for a physical keypress. Measured during
    /// the 3ti.2 spike, it swallowed the first run's keystrokes outright - the text went
    /// to the assistant instead of the target app. An unhandled assistant means the
    /// first dictation after an install types into a dialog, which is why onboarding
    /// owns it alongside the two approvals.
    static func keyboardSetupAssistant(answered: Bool, key: String, path: String) -> Requirement {
        Requirement(
            name: "Keyboard Setup Assistant",
            reads: answered ? "answered for this keyboard" : "will ask on first use",
            // Writing our own key, never aiming at another device's. A cache here
            // already held an entry from an unrelated country-33 device, and
            // initialising this keyboard with country 33 to collide with it would make
            // the device declare something untrue about itself - and would work only
            // until that entry was cleared.
            step: answered ? nil : """
                macOS will raise Keyboard Setup Assistant the first time the
                virtual keyboard types, and it will take those keystrokes.
                Write this device's own answer first:
                    sudo defaults write \(path) keyboardtype -dict-add "\(key)" -int \(VirtualKeyboardIdentity.ansiKeyboardType)
                """
        )
    }
}
