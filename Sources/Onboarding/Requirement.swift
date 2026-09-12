import DriverExtension
import Flavors

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
    /// What each row is called, in the order onboarding prints them.
    ///
    /// One home for the three names, because four readers say them: the factory that
    /// builds each row, the row a failed reading becomes, the readings table `make
    /// check-docs` holds README to, and the tests. Spelled out at each of those, they
    /// are four clocks. [LAW:one-source-of-truth]
    enum Row: String, Sendable, Hashable, CaseIterable {
        case driverExtension = "Driver extension"
        case keyboardHelper = "Keyboard helper"
        case keyboardSetupAssistant = "Keyboard Setup Assistant"
    }

    /// A requirement whose fact could not be read.
    ///
    /// The row stays in the list rather than being dropped or skipped: every requirement
    /// is shown every time, and one that could not be read is never silently absent from
    /// a list a reader takes as complete. It carries a step, so it is never `met` and
    /// never lets `ready` come out true on the strength of a reading nobody took.
    /// [LAW:no-silent-failure]
    static func unreadable(_ row: Row, _ error: any Error) -> Requirement {
        Requirement(name: row.rawValue, reads: "could not be read", step: "\(error)")
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

/// What the `absent` step says to the reader the repo script cannot serve: someone who
/// installed LowTalker.app and has no clone, for whom `scripts/virtual-hid-driver` names
/// a file that is not on their Mac. The app cannot run the install for them - see
/// README's account of why - so the least it can do is name the artifact rather than a
/// path only a developer has. [LAW:no-silent-failure] at the level of an instruction: a
/// step a reader cannot follow is a step that fails without saying so.
///
/// Both halves of the script's `install` are named, because it is two things and only the
/// first is the package: it installs, and then it asks the Manager to activate. Naming
/// the download alone left this reader installed and inactive - the next state down,
/// whose own step then told them to install a package they already had, so nothing here
/// could ever move them off it.
/// The lead-in to the activation is part of this text and not written beside it at the
/// call site, because the activation is the second half of what the script's `install`
/// does for the reader who has it. Written as a separate sentence after the block, it
/// read as a step every reader owed - telling someone who had just run
/// `scripts/virtual-hid-driver install`, which activates, to go and activate again.
///
/// It names the qualifier a second time rather than resting on the "Without one," three
/// lines above, because a step is not read as a paragraph: `Requirement.stepLines` makes
/// every line its own menu item, with no blank line to hold them together. A scope set
/// once at the top reaches whoever is still reading from the top, which is not the reader
/// this block goes wrong for.
private let installWithoutAClone = """
    Without one, install \(DriverPackage.version) of the public package yourself -
    download it, open it, and let the installer finish:
        \(DriverPackage.url)
    Without a clone, ask macOS to activate the driver yourself too.
    """

/// The activation itself, which both of those states end in and neither can reach with
/// the package alone.
///
/// Run as the logged-in user rather than under sudo, and the reason is the same one that
/// keeps this step out of the app's hands entirely: macOS attributes an activation
/// request to whoever asks, and the approval the user gives answers that request. The
/// Manager is named from `DriverProbe`, so this and the `MANAGER` the script runs cannot
/// come to name different binaries. [LAW:one-source-of-truth]
///
/// Begins on a line of its own at every site, so the lead-in sentence each state writes
/// for it does not push this one's first line past the width the rest of the steps wrap
/// to. A step's lines are what the menu makes its items out of.
private let activationWithoutAClone = """
    Run it as you and not under sudo: macOS attributes an activation
    request to whoever asks, and the approval you give answers that
    request.
        \(DriverProbe.managerExecutable) activate
    """

public extension Requirement {
    /// The driver extension low-talker types through.
    ///
    /// Every word `DriverState` can take gets its own step, because they are not degrees
    /// of one problem: a Mac with no package needs an install, a Mac holding a
    /// registration nobody approved needs a click, and a Mac mid-removal needs a
    /// restart. A single "the driver is not ready" would send all three the same way.
    static func driverExtension(_ state: DriverState) -> Requirement {
        Requirement(name: Row.driverExtension.rawValue, reads: reads(for: state), step: step(for: state))
    }

    /// The verdict word itself. Named as a reading rather than reached through
    /// `rawValue` at each site, so the row and the readings table are built from one
    /// expression. [LAW:one-source-of-truth]
    private static func reads(for state: DriverState) -> String { state.rawValue }

    private static func step(for state: DriverState) -> String? {
        switch state {
        // macOS has the extension switched on. `running` additionally means some client
        // has opened it, which is not something a user does and not something to ask for.
        case .enabled, .running:
            nil
        case .absent:
            """
            The driver package is not on this Mac. From a clone of this repo:
                scripts/virtual-hid-driver install
            \(installWithoutAClone)
            \(activationWithoutAClone)
            """
        case .installedInactive:
            """
            The package is installed but macOS holds no registration for it,
            so the activation request never landed. From a clone of this repo,
            whose install asks for it again:
                scripts/virtual-hid-driver install
            Without one, ask macOS to activate it yourself.
            \(activationWithoutAClone)
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
public enum HelperStanding: Sendable, Hashable, CaseIterable {
    /// The app's job holds the Mach service: registered, approved, and answering.
    case holdingTheService
    /// A job under this flavor's label is loaded, and something else holds the service.
    ///
    /// launchd does not make the loser loud: a second claimant on a Mach service name
    /// bootstraps with exit 0, runs, and simply never gets the endpoint. An app in this
    /// state reports its helper enabled and types nothing, which is the whole reason
    /// this is a requirement of its own and not folded into the approval.
    ///
    /// No launchd job can be the holder any more - a flavor's job and its service share
    /// one label, and a second job under that label is refused at bootstrap - so the
    /// holder is a helper running outside launchd, which can be found but not named.
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

    /// Whether a keyboard helper has actually started under this standing.
    ///
    /// Deliberately not "is the app's helper answering". The helper files this keyboard's
    /// answer with Keyboard Setup Assistant in its first moments, before it reaches the
    /// daemon and long before it can win or lose a Mach service name - so a helper that
    /// took the name and one that lost it to the development job have both already had
    /// their chance to file, and the assistant's row is asking about the chance and not
    /// about the name. Reading it as `holdingTheService` alone sent a Mac running the
    /// development helper to wait for a filing that had already happened and already
    /// failed.
    ///
    /// A holder nobody could identify is not one of them: `anotherJobHoldsTheService`
    /// means some job took the name and this Mac could not say whose, so there is no
    /// ground to claim a helper ran. [LAW:no-silent-failure] Written as an exhaustive
    /// switch with no `default`, so a standing added later has to answer this rather than
    /// inheriting whichever answer happened to be the fallback.
    /// [LAW:types-are-the-program]
    var aHelperHasRun: Bool {
        switch self {
        case .holdingTheService: true
        case .anotherJobHoldsTheService, .noJob, .awaitingApproval: false
        }
    }
}

public extension Requirement {
    /// The root helper that owns the virtual keyboard.
    /// [LAW:one-source-of-truth] The flavor itself, not names lifted off it. A step tells a
    /// person which app to turn on and which service was lost, and with two installations
    /// those are two readings of one installation - so they are derived here, together,
    /// from the value that holds both. Passing a name instead lets a step address one copy
    /// while naming the other's, which is the confusion the two flavors exist to prevent.
    static func keyboardHelper(_ standing: HelperStanding, flavor: Flavor) -> Requirement {
        Requirement(name: Row.keyboardHelper.rawValue, reads: reads(for: standing), step: step(for: standing, flavor: flavor))
    }

    private static func reads(for standing: HelperStanding) -> String {
        switch standing {
        case .holdingTheService: "answering"
        case .anotherJobHoldsTheService: "registered, but another job holds the service"
        case .noJob: "not registered"
        case .awaitingApproval: "waiting for approval in Login Items & Extensions"
        }
    }

    private static func step(for standing: HelperStanding, flavor: Flavor) -> String? {
        switch standing {
        case .holdingTheService:
            nil
        case .awaitingApproval:
            """
            Open \(loginItemsPane)
            and turn on \(flavor.displayName). The helper is registered as a login item
            and waits there until you do.
            """
        case .noJob:
            """
            launchd holds no job for the helper. Launch \(flavor.displayName) once - it
            registers on every launch - and turn it on in
            \(loginItemsPane) if it asks.
            """
        case .anotherJobHoldsTheService:
            """
            Something else holds \(flavor.machServiceName), so this app's
            helper never got the name and answers nothing, however
            healthy it looks. It cannot be another launchd job - a
            job and its service share one label here, and a second
            under it is refused. A helper left running by hand is
            what this usually is. Find it:
                pgrep -fl lowtalker-keyboardd
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
    ///
    /// The only row whose step names nobody and nothing to install. The write wants root,
    /// which is why it used to be a `sudo` command printed for a reader to paste - but
    /// the keyboard helper is root, knows which keyboard it owns, and has to be running
    /// before the keyboard can type at all, so it files the answer as it starts. What is
    /// left to say is which row this one is waiting behind. [LAW:one-source-of-truth] The
    /// helper writes and this reads, and both take the key and the file from
    /// `VirtualKeyboardIdentity`.
    ///
    /// Which makes the helper's standing part of this row's step and not context around
    /// it. "Wait for the helper to file it" is true only while the helper is not yet
    /// answering; said to someone whose helper IS answering, it is an instruction to wait
    /// for something that already happened, and the one thing that can actually be
    /// wrong - the filing failed, and the helper said why - goes unmentioned. A step that
    /// sends a reader to wait out a failure is that failure staying silent at the level
    /// of an instruction. [LAW:no-silent-failure]
    ///
    /// - Parameter aHelperHasRun: whether a keyboard helper has already started and so
    ///   already had its chance to file this, from the row above, which is read first for
    ///   exactly this reason. See `HelperStanding.aHelperHasRun` for why that is a wider
    ///   question than whether the app's own helper holds the service.
    /// - Parameter helperSubsystem: the subsystem the helper logs under, which is its own
    ///   Mach service name. Passed in rather than reached for, so this stays a pure
    ///   function of what onboarding read. [LAW:effects-at-boundaries]
    static func keyboardSetupAssistant(answered: Bool, aHelperHasRun: Bool, helperSubsystem: String) -> Requirement {
        Requirement(
            name: Row.keyboardSetupAssistant.rawValue,
            reads: reads(forAnswered: answered),
            step: answered ? nil : step(aHelperHasRun: aHelperHasRun, helperSubsystem: helperSubsystem)
        )
    }

    private static func reads(forAnswered answered: Bool) -> String {
        answered ? "answered for this keyboard" : "will ask on first use"
    }

    /// Both arms open the same way, because the reader needs the same fact either way:
    /// the assistant is about to take the first line typed. They differ in what is left
    /// to do about it, which is what the helper's standing decides.
    ///
    /// The window the running arm names is a guess, and the step says so rather than
    /// letting the reader take it for a promise. The standing it is chosen from carries
    /// no time: `holdingTheService` means a helper is up now, not that it started
    /// recently, and a `KeepAlive` daemon holds the name for as long as the Mac is up.
    /// The filing is logged once, at that start, so a window that opens after it comes
    /// back empty - and empty is what a reader takes for "no failure here", which is the
    /// silence this arm exists to break. [LAW:no-silent-failure]
    private static func step(aHelperHasRun: Bool, helperSubsystem: String) -> String {
        let opening = """
            macOS raises Keyboard Setup Assistant the first time the virtual
            keyboard types, and it takes those keystrokes. The keyboard helper
            files this keyboard's own answer as it starts,
            """
        return aHelperHasRun ? """
            \(opening) and one has already
            started - so the filing itself is what failed. It logged the reason as it
            started, which may be further back than this window - widen it if nothing
            comes back:
                /usr/bin/log show --predicate 'subsystem == "\(helperSubsystem)"' --last 24h
            """ : """
            \(opening) so this clears itself
            once the helper above is answering.
            """
    }
}

// MARK: - the vocabulary README keeps a copy of

public extension Requirement {
    /// Every reading every row can take, each paired with the row it belongs to.
    ///
    /// README.md lists these for a reader following the runbook by hand. It cannot read a
    /// Swift enum, so it keeps a copy per row, and `make check-docs` reads this to hold
    /// each copy to it. Derived from the same `reads(for:)` the rows themselves are built
    /// from rather than written out a second time, so a case added to `DriverState` or
    /// `HelperStanding` reaches every reader that quotes the list.
    /// [LAW:one-source-of-truth]
    ///
    /// Every row is in it, and each reading carries the row it belongs to rather than
    /// leaving that to what the caller happens to know it asked for. The table covered
    /// only the helper's five readings before, unlabelled - so the assistant's two sat
    /// hand-copied into README with nothing checking them, and nothing about the table
    /// said they were missing. A vocabulary table whose gaps are invisible to the reader
    /// trusting it is the drift it exists to catch. [LAW:composability]
    ///
    /// `unreadable`'s reading is in none of them: it belongs to no row's own vocabulary,
    /// being the one thing every row says when the machine could not be read, and README
    /// describes it once as exactly that.
    static var readings: [(row: Row, reading: String)] {
        DriverState.allCases.map { (row: Row.driverExtension, reading: reads(for: $0)) }
            + HelperStanding.allCases.map { (row: Row.keyboardHelper, reading: reads(for: $0)) }
            + [true, false].map { (row: Row.keyboardSetupAssistant, reading: reads(forAnswered: $0)) }
    }
}
