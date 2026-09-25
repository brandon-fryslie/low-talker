import Choices
import DriverExtension
import Flavors
import Grants

/// One thing that must hold before low-talker can hear and type, as this Mac actually stands.
///
/// [LAW:one-type-per-behavior] Very different facts - a privacy grant only a person can
/// give, an input method macOS switches on, a driver extension's registration, a launchd
/// job's hold on a Mach service, a cached answer from a setup assistant - are one type with
/// one instance per row, because what a reader does with them does not differ: read what is
/// there, and do the step when there is one. A type per requirement would be a rendering
/// per requirement of one shape.
public struct Requirement: Sendable, Hashable {
    /// Which requirement this is. Its name, its explanation and what asking for it does are
    /// all read off the row, so no reader keeps a second copy of any of them.
    public let row: Row
    /// What was read off this Mac. Shown whether or not there is a step, because a
    /// requirement that says only "not ready" is one nobody can act on or report.
    public let reads: String
    /// What is left for a person to do, and nil when nothing is. Genuinely absent rather
    /// than an empty string: "nothing to do" and "a step nobody wrote" are different
    /// facts, and a reader that cannot tell them apart will print the second as the
    /// first.
    public let step: String?
    /// The row this one waits on, when it cannot be asked for until that one is met.
    public let waitsOn: Row?

    /// What must hold, in the words the menu, the CLI and the guided setup all use.
    public var name: String { row.rawValue }

    public var met: Bool { step == nil }

    public init(row: Row, reads: String, step: String?, waitsOn: Row? = nil) {
        self.row = row
        self.reads = reads
        self.step = step
        self.waitsOn = waitsOn
    }
}

public extension Requirement {
    /// Every requirement there is, in the order onboarding prints them and the guided setup
    /// walks them: what hearing needs, then what the chosen hotkey needs, then what the
    /// chosen delivery needs.
    ///
    /// Accessibility comes before Input Monitoring because granting it normally grants the
    /// other: once Accessibility is held, macOS answers Input Monitoring from it, so that
    /// step reads allowed and the walk passes it without a second dialog. See
    /// `EventTapAccess`.
    ///
    /// This is the one list of what low-talker asks of a Mac. The CLI prints it, the menu
    /// shows it, and the guided setup is a walk over it, so a grant added here reaches every
    /// surface and a grant missing here is missing from all of them. [LAW:one-source-of-truth]
    enum Row: String, Sendable, Hashable, CaseIterable {
        case microphone = "Microphone"
        case accessibility = "Accessibility"
        case inputMonitoring = "Input Monitoring"
        case inputMethod = "Input method"
        case driverExtension = "Driver extension"
        case keyboardHelper = "Keyboard helper"
        case keyboardSetupAssistant = "Keyboard Setup Assistant"

        /// What a row is needed for: hearing at all, one way of hearing the hotkey, or one
        /// way of delivering the words.
        public enum Serves: Sendable, Hashable {
            case everySetup
            case hearing(HotkeySource)
            case delivery(Delivery)
        }

        /// [LAW:dataflow-not-control-flow] Which setups need a row is a value on the row, so
        /// choosing a hotkey or a delivery changes the list by what it holds, and no surface
        /// decides for itself which rows to show.
        public var serves: Serves {
            switch self {
            case .microphone: .everySetup
            case .inputMonitoring, .accessibility: .hearing(.eventTap)
            case .inputMethod: .delivery(.inputMethod)
            case .driverExtension, .keyboardHelper, .keyboardSetupAssistant: .delivery(.virtualKeyboard)
            }
        }

        /// Whether any of these setups needs this row. The app passes the one setup it has;
        /// the CLI, which has none, passes every choice there is and gets every row.
        public func isNeeded(deliveries: [Delivery], sources: [HotkeySource]) -> Bool {
            switch serves {
            case .everySetup: true
            case .hearing(let source): sources.contains(source)
            case .delivery(let delivery): deliveries.contains(delivery)
            }
        }

        /// Whether only the app itself can read this row.
        ///
        /// macOS keys these grants to the app that holds them, so another process asking
        /// about them is told about itself: a CLI run from a terminal reading the
        /// microphone grant would report the terminal's. A reading of the wrong app is worse
        /// than none, so these rows are read by the app and named, unread, everywhere else.
        /// [LAW:no-silent-failure]
        public var readOnlyByTheApp: Bool {
            switch self {
            case .microphone, .inputMonitoring, .accessibility: true
            case .inputMethod, .driverExtension, .keyboardHelper, .keyboardSetupAssistant: false
            }
        }

        /// Whether dictation cannot start at all without this row. The rest let the loop come
        /// up and stop only the words at the keyboard: an unapproved helper or a missing
        /// driver fails the press that reaches it, with its reason, and the assistant's
        /// answer is filed by the helper. The app waits on these rows and comes up when
        /// they are met.
        public var stopsDictation: Bool {
            switch self {
            case .microphone, .inputMonitoring, .accessibility, .inputMethod: true
            case .driverExtension, .keyboardHelper, .keyboardSetupAssistant: false
            }
        }

        /// The rows a person must allow before this hotkey hears anything: the grants it
        /// asks for, read off the list rather than kept beside it.
        public static func grants(for source: HotkeySource) -> [Row] {
            allCases.filter { $0.serves == .hearing(source) }
        }
    }

    /// A requirement whose fact could not be read.
    ///
    /// The row stays in the list rather than being dropped or skipped: every requirement
    /// is shown every time, and one that could not be read is never silently absent from
    /// a list a reader takes as complete. It carries a step, so it is never `met` and
    /// never lets `ready` come out true on the strength of a reading nobody took.
    /// [LAW:no-silent-failure]
    static func unreadable(_ row: Row, _ error: any Error) -> Requirement {
        Requirement(row: row, reads: "could not be read", step: "\(error)")
    }
}

public extension HotkeySource {
    /// What macOS asks of the user before this hearing hears anything, as a menu says it,
    /// named from the rows it needs. [LAW:one-source-of-truth]
    var asks: String {
        let grants = Requirement.Row.grants(for: self).map(\.rawValue)
        return grants.isEmpty ? "needs nothing" : "needs " + grants.joined(separator: " and ")
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
/// This is what `lowtalker onboard` prints, what the menu-bar app shows, and what its guided
/// setup walks. It is computed rather than printed so a test can read it as a value, and so
/// every surface says the same words without any of them spelling them a second time.
/// [LAW:effects-at-boundaries]
public struct Readiness: Sendable, CustomStringConvertible {
    public let requirements: [Requirement]
    /// Rows the setup needs that this reader could not read, because only the app can.
    /// Named rather than dropped, so a list read from the CLI does not pass for the whole.
    public let notReadHere: [Requirement.Row]

    public init(_ requirements: [Requirement], notReadHere: [Requirement.Row] = []) {
        self.requirements = requirements
        self.notReadHere = notReadHere
    }

    /// Nothing this reader could read is left for anyone to do.
    public var ready: Bool { requirements.allSatisfy(\.met) }

    /// The requirements with something left to do, in the list's order.
    public var unmet: [Requirement] { requirements.filter { !$0.met } }

    /// Every requirement, every time, in a fixed order - the met ones included. A list
    /// that showed only what was wrong would leave a reader unable to tell "checked and
    /// fine" from "never checked". [LAW:dataflow-not-control-flow]
    ///
    /// The rows this reader could not read sit where the list puts them, so the CLI's
    /// printout and the app's menu run in one order.
    public var description: String {
        let read: [(row: Requirement.Row, text: String)] = requirements.map { (row: $0.row, text: $0.description) }
        let unread: [(row: Requirement.Row, text: String)] = notReadHere.map {
            (row: $0, text: "\($0.rawValue): only the app can read this; see Set Up in its menu")
        }
        let order = Requirement.Row.allCases
        let lines: [(row: Requirement.Row, text: String)] = read + unread
        return lines
            .sorted { order.firstIndex(of: $0.row)! < order.firstIndex(of: $1.row)! }
            .map(\.text).joined(separator: "\n")
    }
}

// MARK: - what only the app can read

/// Where each privacy grant is switched on by hand. Named once, because every step that
/// sends a reader to one of these panes spells it from here.
private func privacyPane(_ row: Requirement.Row) -> String {
    "System Settings > Privacy & Security > \(row.rawValue)"
}

public extension Requirement {
    /// A grant's row from the app's reading, or a row saying the reading failed: a grant
    /// that could not be read is unmet, and says why. [LAW:no-silent-failure]
    static func privacy(
        _ row: Row, _ reading: Result<PrivacyReading, PrivacyReadingFailure>, flavor: Flavor,
        _ build: (PrivacyReading) -> Requirement
    ) -> Requirement {
        switch reading {
        case .success(let reading): build(reading)
        case .failure(let failure):
            Requirement(row: row, reads: "could not be read: \(failure)", step: "Try again in a moment. If it stays, reinstall \(flavor.displayName).")
        }
    }

    /// The microphone, which every setup needs: nothing is heard without it.
    ///
    /// - Parameter withheld: why macOS withholds it, or nil when it is allowed.
    static func microphone(_ withheld: MicrophoneAuthorization.Withheld?, flavor: Flavor) -> Requirement {
        Requirement(row: .microphone, reads: reads(forMicrophone: withheld), step: step(forMicrophone: withheld, flavor: flavor))
    }

    private static func reads(forMicrophone withheld: MicrophoneAuthorization.Withheld?) -> String {
        switch withheld {
        case nil: "allowed"
        case .notDetermined: "not asked yet"
        case .denied: "turned off"
        case .restricted: "restricted by policy"
        }
    }

    private static func step(forMicrophone withheld: MicrophoneAuthorization.Withheld?, flavor: Flavor) -> String? {
        switch withheld {
        case nil:
            nil
        case .notDetermined:
            "Allow it in \(GuidedSetup.title(for: flavor))"
        case .denied:
            "Turn on \(flavor.displayName) in \(privacyPane(.microphone))."
        case .restricted:
            "A policy on this Mac blocks it."
        }
    }

    /// Input Monitoring, which the event tap needs to read the keys. While Accessibility is
    /// off, tccd answers this from it and no dialog can show; allowing Accessibility brings
    /// it along. See `EventTapAccess`.
    static func inputMonitoring(held: Bool, accessibilityHeld: Bool, flavor: Flavor) -> Requirement {
        accessibilityHeld || held
            ? privacyGrant(.inputMonitoring, held: held, flavor: flavor)
            : Requirement(
                row: .inputMonitoring, reads: reads(forGrantHeld: held),
                step: "Allow Accessibility first. This comes with it.", waitsOn: .accessibility)
    }

    /// Accessibility, which the event tap needs to hold the chord back from the app in front.
    static func accessibility(held: Bool, flavor: Flavor) -> Requirement {
        privacyGrant(.accessibility, held: held, flavor: flavor)
    }

    /// [LAW:one-type-per-behavior] The two grants read, word and step, the same way; only
    /// the row differs.
    private static func privacyGrant(_ row: Row, held: Bool, flavor: Flavor) -> Requirement {
        Requirement(row: row, reads: reads(forGrantHeld: held), step: held ? nil : "Allow it in \(GuidedSetup.title(for: flavor)) or \(privacyPane(row)).")
    }

    private static func reads(forGrantHeld held: Bool) -> String {
        held ? "allowed" : "not allowed"
    }
}

// MARK: - the input method

public extension Requirement {
    /// Whether this installation's input method is switched on. macOS asks the person before
    /// an app may switch one on, so this is a grant, and the one the input method delivery
    /// waits on. Copying and registering it ask nobody, and the app does both on its own.
    static func inputMethod(switchedOn: Bool, flavor: Flavor) -> Requirement {
        Requirement(row: .inputMethod, reads: reads(forSwitchedOn: switchedOn), step: switchedOn ? nil : "Switch it on in \(GuidedSetup.title(for: flavor))")
    }

    private static func reads(forSwitchedOn switchedOn: Bool) -> String {
        switchedOn ? "switched on" : "switched off"
    }
}

// MARK: - the driver extension

/// Where the two approvals live. Named once because every step that asks for a click
/// ends up here, and a reader following one of them to a pane that does not exist is a
/// reader who stops.
private let loginItemsPane = "System Settings > General > Login Items & Extensions"

/// Said beside every command that installs, because it is the one mistake that sends the
/// install somewhere it cannot finish: macOS attributes an activation request to whoever
/// asks, and the approval the user gives answers that request. The command takes sudo
/// itself for the file steps. A step's lines are what the menu makes its items out of, so
/// this is written to stand on its own line.
private let notUnderSudo = """
    Run it as you, not under sudo: it asks for your password itself.
    """

/// Said beside every command that asks macOS to activate the driver, because the dialog
/// that follows is the one macOS words with another product's name: the package's own
/// Manager app files the request, so the notice reads "Karabiner-VirtualHIDDevice-Manager"
/// would like to use a new driver extension, which is what it said on studious (macOS
/// 15.0.1) on 2026-09-24. A person told only of "the driver" meets a name they never
/// installed.
private let managerNotice = """
    macOS then asks about "Karabiner-VirtualHIDDevice-Manager": the driver
    is the open-source Karabiner virtual keyboard, and that is its installer.
    """

public extension Requirement {
    /// The driver extension low-talker types through.
    ///
    /// Every word `DriverState` can take gets its own step, because they are not degrees
    /// of one problem: a Mac with no package needs an install, a Mac holding a
    /// registration nobody approved needs a click, and a Mac mid-removal needs a
    /// restart. A single "the driver is not ready" would send all three the same way.
    ///
    /// - Parameter cli: the lowtalker binary this reader has, which every step that repairs
    ///   the driver names. Each app carries one, so this is never a path only a clone has:
    ///   the CLI passes its own, the app the one inside its bundle.
    static func driverExtension(_ state: DriverState, cli: String) -> Requirement {
        Requirement(row: .driverExtension, reads: reads(for: state), step: step(for: state, cli: cli))
    }

    /// The verdict word itself. Named as a reading rather than reached through
    /// `rawValue` at each site, so the row and the readings table are built from one
    /// expression. [LAW:one-source-of-truth]
    private static func reads(for state: DriverState) -> String { state.rawValue }

    private static func step(for state: DriverState, cli: String) -> String? {
        switch state {
        // macOS has the extension switched on. `running` additionally means some client
        // has opened it, which is not something a user does and not something to ask for.
        case .enabled, .running:
            nil
        case .absent:
            """
            The driver package is not on this Mac. This downloads and verifies
            it, installs it, and asks macOS to activate it:
                \(DriverInstall.command(cli, "install"))
            \(notUnderSudo)
            \(managerNotice)
            """
        case .installedInactive:
            """
            The package is installed but macOS holds no registration for it,
            so the activation request never landed. This asks for it again:
                \(DriverInstall.command(cli, "install"))
            \(notUnderSudo)
            \(managerNotice)
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
                \(DriverInstall.command(cli, "remove"))
                \(DriverInstall.command(cli, "install"))
            \(notUnderSudo)
            \(managerNotice)
            """
        // The probe said it could not read the machine, or read a registration it could
        // not name. Either way the reason is already on stderr, and pointing at it beats
        // inventing a step for a state nobody has identified. [LAW:no-silent-failure]
        case .unknown:
            """
            This Mac's driver state could not be read. This says what could
            not be read, and why:
                \(DriverInstall.command(cli, "state"))
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
    /// The holder is not a launchd job under this flavor's label - that one is read
    /// separately, as `aBootstrappedJobHoldsTheLabel` - so it is a helper running outside
    /// launchd, or a job filed under some *other* label that names this service. Findable
    /// either way, nameable by neither.
    case anotherJobHoldsTheService
    /// A job bootstrapped from a plist in /Library/LaunchDaemons holds this flavor's
    /// label, so the app's own `SMAppService` registration never became the running job.
    ///
    /// [LAW:types-are-the-program] This is the state the label collapse made reachable and
    /// left unrepresentable. `launchctl bootstrap` refuses a second job under a held label,
    /// which is what the one-label design rests on - but `SMAppService.register()` is not
    /// `bootstrap` and gets no such refusal. So `scripts/keyboard-helper install` followed
    /// by launching the app is a real, ordinary sequence that ends here, and folding it in
    /// with "a holder that cannot be named" threw away the one fact that makes it fixable:
    /// this holder has a plist, at a path that can be printed and removed.
    case aBootstrappedJobHoldsTheLabel
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
    /// daemon and long before it can win or lose a Mach service name, so the assistant's
    /// row is asking about that chance and not about the name.
    ///
    /// A holder nobody could identify has had no such chance: `anotherJobHoldsTheService`
    /// means some job took the name and this Mac could not say whose, so there is no
    /// ground to claim a helper ran. [LAW:no-silent-failure] Written as an exhaustive
    /// switch with no `default`, so a standing added later has to answer this rather than
    /// inheriting whichever answer happened to be the fallback.
    /// [LAW:types-are-the-program]
    ///
    /// `aBootstrappedJobHoldsTheLabel` answers `false` although its holder is named and
    /// is this same binary: what was read is that a plist holds the label, not that the
    /// helper it names ever ran. It may have refused to start - a plist passing no
    /// `--flavor` exits before it knows which service it would have been - or never
    /// spawned at all, which is what a BTM record rebound to the plist's path did. Its row
    /// carries a step that removes the plist, after which the app's own helper starts and
    /// files afresh; sending the reader to a log first is sending them to read a filing
    /// that may not exist.
    var aHelperHasRun: Bool {
        switch self {
        case .holdingTheService: true
        case .anotherJobHoldsTheService, .aBootstrappedJobHoldsTheLabel, .noJob, .awaitingApproval: false
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
        Requirement(row: .keyboardHelper, reads: reads(for: standing), step: step(for: standing, flavor: flavor))
    }

    private static func reads(for standing: HelperStanding) -> String {
        switch standing {
        case .holdingTheService: "answering"
        case .anotherJobHoldsTheService: "registered, but another job holds the service"
        case .aBootstrappedJobHoldsTheLabel: "a bootstrapped job holds the label, so this app's registration never ran"
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
            launchd holds no job for the helper. \(flavor.displayName) registers it
            when you press Allow in \(GuidedSetup.title(for: flavor)), in its
            menu; then turn it on in \(loginItemsPane).
            """
        case .anotherJobHoldsTheService:
            """
            Something else holds \(flavor.machServiceName), so this app's
            helper never got the name and answers nothing, however
            healthy it looks. Two things it can be, and the second is
            the one a reader misses: a helper left running by hand,
            or a launchd job filed under some other label that names
            this service - which is what every installation of this
            app before the labels were joined looks like. Find both:
                pgrep -fl lowtalker-keyboardd
                sudo grep -l '>\(flavor.machServiceName)<' /Library/LaunchDaemons/*.plist
            """
        case .aBootstrappedJobHoldsTheLabel:
            """
            A job bootstrapped from /Library/LaunchDaemons holds
            \(flavor.launchdLabel), so \(flavor.displayName) registered its
            helper and launchd kept the job already under that label -
            this app's copy never spawned. scripts/keyboard-helper
            installs that job; remove it and launch the app again:
                scripts/keyboard-helper uninstall \(flavor)
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
            row: .keyboardSetupAssistant,
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
        // One typed list per row, joined once: a single expression chaining all of them is
        // more than Swift 6.1's type checker will finish in time.
        let answers: [MicrophoneAuthorization.Withheld?] = [nil] + MicrophoneAuthorization.Withheld.allCases
        let microphone: [(row: Row, reading: String)] = answers.map { (row: Row.microphone, reading: reads(forMicrophone: $0)) }
        let inputMonitoring: [(row: Row, reading: String)] = [true, false].map { (row: Row.inputMonitoring, reading: reads(forGrantHeld: $0)) }
        let accessibility: [(row: Row, reading: String)] = [true, false].map { (row: Row.accessibility, reading: reads(forGrantHeld: $0)) }
        let inputMethod: [(row: Row, reading: String)] = [true, false].map { (row: Row.inputMethod, reading: reads(forSwitchedOn: $0)) }
        let driver: [(row: Row, reading: String)] = DriverState.allCases.map { (row: Row.driverExtension, reading: reads(for: $0)) }
        let helper: [(row: Row, reading: String)] = HelperStanding.allCases.map { (row: Row.keyboardHelper, reading: reads(for: $0)) }
        let assistant: [(row: Row, reading: String)] = [true, false].map { (row: Row.keyboardSetupAssistant, reading: reads(forAnswered: $0)) }
        return [microphone, accessibility, inputMonitoring, inputMethod, driver, helper, assistant].flatMap { $0 }
    }
}
