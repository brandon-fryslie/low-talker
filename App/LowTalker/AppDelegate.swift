import AppKit
import Choices
import Dictation
import Flavors
import Grants
import InputSource
import Insertion
import KeyboardLayout
import KeyboardService
import LowTalkerCore
import Onboarding
import ServiceManagement
import Signals
import Typing
import os

/// The menu-bar agent. `LSUIElement` keeps it out of the Dock, so the status item
/// is the app's only surface; the delegate exists to install it, to start the model
/// loading the moment the app is up, and to hand the loop its microphone, engine and
/// the output the user chose.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // [LAW:no-ambient-temporal-coupling] NSStatusBar is only usable once the
    // application object exists, which is after this delegate is allocated. Lazy
    // creation ties the item's lifetime to first use instead of to an optional that
    // every later reader would have to unwrap.
    private lazy var statusItem: NSStatusItem = {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        return item
    }()

    /// The one menu, emptied and rebuilt from a fresh reading every time it is about to
    /// be shown. It holds no state of its own: what a reader sees is what
    /// `menuNeedsUpdate` just read, never a title some earlier code path remembered to
    /// keep in step. [LAW:one-source-of-truth]
    private lazy var menu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }()

    /// What the engine is doing, and whether the hotkey is being watched. The two
    /// things in the menu that cannot be read on demand: they arrive from the load's
    /// and the tap's own callbacks, so they are held here while everything else is read
    /// at the moment the menu opens. Launch sets the hotkey's before it returns, so no
    /// menu can open on an empty string.
    ///
    /// The engine's is also the status icon's face, since a first load runs for minutes
    /// and an icon that looks ready through them reads as an app that is not answering.
    /// Lazy so it can count from `launched`; only `show(_:)` sets it, which redraws the icon.
    private lazy var engineReadiness: EngineReadiness = .preparing(nil, since: launched)
    private var hotkeyStatus = ""

    /// When this process began, which every readout of the engine's wait counts from.
    private let launched = ContinuousClock.now

    /// The same readouts in the unified log, where `log show` can time them: a menu
    /// nobody has open is no way to measure a launch, and no way for an agent to check
    /// what the app is showing without a screen. [LAW:verifiable-goals]
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "engine")
    /// One line per press: what was heard, how long after key-up, and what was typed.
    private let sessions = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "dictation")

    /// [LAW:parse-dont-validate] The one place this process learns which of the two
    /// installations it is. macOS launched it under one bundle identifier or the other,
    /// and everything keyed to the installation - the helper's job, the config file, the
    /// chord, the name in the menu - is read from this and never decided again.
    ///
    /// [LAW:no-silent-failure] A bundle identifier that is neither flavor's is a
    /// misconfigured build, and guessing is the one wrong answer: reading a development
    /// bundle as `.release` would point this copy's helper, config and hotkey at the
    /// installed copy's, which is the whole failure the two flavors exist to prevent.
    /// There is nothing to fall back to, so it stops here, at launch, where the reason is
    /// legible - rather than at the first keypress, in the other app.
    static let flavor: Flavor = {
        let identifier = Bundle.main.bundleIdentifier
        guard let identifier, let flavor = Flavor(bundleIdentifier: identifier) else {
            let known = Flavor.allCases.map(\.bundleIdentifier).joined(separator: " or ")
            fatalError("launched under bundle identifier \(identifier ?? "none"), which is neither installation: expected \(known)")
        }
        return flavor
    }()

    /// The CLI this bundle carries, which the driver's onboarding steps name: a person who
    /// installed only this app has it, and it is the one the helper this app registers
    /// admits.
    static let carriedCLI = CarriedCLI.path(in: Bundle.main.bundleURL)

    /// The helper's registration, from the bundle's own launchd plist. One instance,
    /// because registering and asking where the registration stands are two questions
    /// about one record. [LAW:one-source-of-truth] The plist is named from the flavor, so
    /// each installation registers its own job and neither can adopt the other's record.
    private let helperService = SMAppService.daemon(plistName: "\(AppDelegate.flavor.launchdLabel).plist")

    /// [LAW:one-source-of-truth] Every engine status passes through here, so the
    /// menu and the log never tell different stories.
    private func show(_ readiness: EngineReadiness) {
        engineReadiness = readiness
        drawStatusIcon()
        log.info("model: \(readiness.readout(at: .now), privacy: .public)")
    }

    private func showHotkeyStatus(_ status: String) {
        hotkeyStatus = status
        log.notice("hotkey: \(status, privacy: .public)")
    }

    /// The root keyboard helper, registered from the bundle's own launchd plist.
    ///
    /// Two callers. The keyboard helper's step in setup, which a person starts: a first
    /// registration is what lands the job in Login Items as "requires approval" and puts
    /// macOS's background item notice on screen. And adoption, launch included, but only
    /// once the job is already enabled, where registering again shows nothing and keeps the
    /// job pointing at this copy of the app; see `install(_:)`.
    ///
    /// Answers with why the registration failed, or nil when it landed. `SMAppService`
    /// answers only whether this app's own registration is approved, and that is one of two
    /// readings the helper's row needs - the other, which job actually holds the Mach
    /// service, only launchd can give. Both are taken together at the next reading.
    private func registerKeyboardHelper() -> String? {
        do {
            try helperService.register()
            return nil
        } catch {
            log.notice("keyboard helper: register — \(error.localizedDescription, privacy: .public)")
            // On the first registration of every install this throws "Operation not
            // permitted": smd will not bootstrap a daemon nobody has approved yet, and the
            // registration it made reads back as waiting for approval. That is the step on
            // the way in, and the helper's row says what is left. Anything else is a
            // registration that did not land, and the caller says why. [LAW:no-silent-failure]
            return helperService.status == .requiresApproval
                ? nil : "the keyboard helper could not be registered: \(error.localizedDescription)"
        }
    }

    @objc private func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private let capture = AudioCapture()
    /// Kept for the app's life so the XPC connection to the helper stays open: launchd
    /// starts the job on the first call, and that is a cost to pay once, not per press.
    /// Lazy, so an installation on the input method never dials a helper it never registered.
    private lazy var helper = HelperConnection(flavor: AppDelegate.flavor)
    /// Raised on the way out, so a session still typing stops short of its remaining
    /// keys rather than being waited out in full.
    private let interrupt = Interrupt()

    /// A signal is a third way to ask the app to go, after the menu item and Cmd-Q, and
    /// it goes the same way they do rather than by the default disposition, which ends
    /// the process where it stands - with a session's keys still down, if one is in
    /// flight. [LAW:single-enforcer] `terminate` is the door; this only knocks on it.
    ///
    /// The knock is posted to the main run loop rather than made from the handler, and
    /// that is load-bearing: `terminate` answers `.terminateLater` by spinning a nested
    /// event loop until the reply comes, and the reply is a main-queue block, which
    /// cannot run while another main-queue block is still on the stack. A handler that
    /// called `terminate` itself would hang the app it was trying to end. Every other way
    /// in reaches `terminate` from the run loop, and so does this - in the common modes,
    /// so an open menu is not a signal ignored. [LAW:no-ambient-temporal-coupling]
    ///
    /// Held from the moment the delegate exists, which is before the run loop starts: a
    /// signal arriving in that window is answered as the first thing the running app does.
    private let signals = SignalWatch { _ in
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    }

    /// The engine, from the moment launch starts loading it. Awaiting the task is how
    /// a session gets the transcriber; a task still running is the app's "still
    /// loading" state, held here rather than inside the engine.
    ///
    /// [LAW:no-ambient-temporal-coupling] Nothing can call the transcriber before it
    /// is resident: the only handle is the task, and the task yields the value only
    /// when the initializer has returned. Lazy so that it can name `loadEngine`, which
    /// reports to this delegate's menu; touching it is what starts the load.
    private lazy var engine: Task<WhisperKitTranscriber, any Error> = Task { try await loadEngine() }

    // MARK: - the delivery and the hotkey source

    /// Where this installation's two choices are kept: its own defaults domain, so the two
    /// installations choose apart. [LAW:one-source-of-truth] The menu and the first-launch
    /// questions write them, launch reads them, `lowtalker onboard` reads them from outside,
    /// and `KeptChoices` holds the one spelling of each key.
    private let kept = KeptChoices(.standard)

    /// The delivery the user chose, or nil for an installation that has never been asked.
    private var chosenDelivery: Delivery? {
        get { kept.delivery }
        set { kept.delivery = newValue }
    }

    /// The hotkey source the user chose, or nil for an installation that has never been asked.
    private var chosenSource: HotkeySource? {
        get { kept.source }
        set { kept.source = newValue }
    }

    /// What a loop is built from: how the words arrive and how the chord is heard.
    ///
    /// [LAW:locality-or-seam] Two independent choices. Every pairing is a loop, the source
    /// decides only the hotkey and the delivery only the executor, so nothing here reads
    /// one to decide anything about the other.
    private struct Setup: Equatable {
        let delivery: Delivery
        let source: HotkeySource
    }

    /// The choices the app is working to: the listening loop's, or the kept ones while
    /// nothing listens yet, so a choice made then is shown as made.
    private var shownChoices: (delivery: Delivery?, source: HotkeySource?) {
        (listening?.setup.delivery ?? chosenDelivery, listening?.setup.source ?? chosenSource)
    }

    /// Both kept choices, or nil while either has never been made.
    private var chosenSetup: Setup? {
        guard let delivery = chosenDelivery, let source = chosenSource else { return nil }
        return Setup(delivery: delivery, source: source)
    }

    /// The loop that is listening now, and the setup it was built from.
    private struct Listening {
        let setup: Setup
        let hotkey: Hotkey
        let dictation: Dictation
    }

    private var listening: Listening?

    /// The switch in progress, which the next one waits behind.
    ///
    /// [LAW:no-ambient-temporal-coupling] A switch awaits the old loop's sessions, and a
    /// second choice made during that wait would otherwise build a loop beside the first
    /// one's and leave a hotkey up that nothing can take down. Each switch awaits the one
    /// before it, so there is only ever one loop being built.
    private var switching: Task<Void, Never>?
    /// Set the moment a quit is asked for, and never cleared.
    ///
    /// A choice taken after that point would chain a switch behind the one the quit is
    /// waiting on, and that switch installs a fresh tap - after the quit has taken the
    /// old one down, and with nothing left to wait for its sessions. The app would exit
    /// with a live tap in front of the session's keyboard. [LAW:no-ambient-temporal-coupling]
    private var quitting = false

    /// The words the last press copied, while no press has begun since: what the Insert
    /// Dictation service hands back, and what the status item's icon is drawn from, so the
    /// icon cannot say something the service would not return. [LAW:one-source-of-truth]
    private var lastDictation: String? {
        didSet { drawStatusIcon() }
    }

    private var wordsOnClipboard: Bool { lastDictation != nil }

    /// Why the last press's words reached no cursor, while no press has begun since.
    private var lastFailure: String?

    private func drawStatusIcon() {
        // Named from the flavor, because with both copies installed there are two of
        // these icons in the menu bar and this label is what tells them apart - to a
        // reader with VoiceOver, and to an agent reading the bar over Accessibility.
        statusItem.button?.image = NSImage(
            systemSymbolName: engineReadiness.symbolName(wordsOnClipboard: wordsOnClipboard),
            accessibilityDescription: engineReadiness.iconDescription(for: Self.flavor.displayName, wordsOnClipboard: wordsOnClipboard))
    }

    /// Takes `setup` down to the loop: the old loop's hotkey comes down first, ending any
    /// press it had open, its sessions are waited out, and then the source's hotkey goes up
    /// in front of a loop whose output is the delivery's.
    ///
    /// Queued behind any switch still in progress; see `switching`.
    private func choose(_ setup: Setup) async {
        let before = switching
        let this = Task {
            await before?.value
            await adopt(setup)
        }
        switching = this
        switchesInFlight += 1
        await this.value
        switchesInFlight -= 1
        settleOwedReading()
    }

    /// How many switches are queued or running. While any is, the loop is being rebuilt by
    /// someone already, and a grant noticed in the meantime is that switch's to take up.
    private var switchesInFlight = 0

    private func adopt(_ setup: Setup) async {
        if let previous = listening {
            listening = nil
            await previous.hotkey.stopAndDeliver()
            // A refused wait is reported and the switch still made: a loop that cannot be
            // replaced would be the worse failure of the two. [LAW:no-silent-failure]
            do { try await previous.dictation.finish() } catch { report(.failure(error)) }
        }
        // `lastDictation` is left as it stands: a session the wait let finish may just
        // have copied, and words on the clipboard stay there whichever delivery comes next.
        // [LAW:no-ambient-temporal-coupling] The delivery is made ready before the hotkey
        // goes up, so no press is heard that has nowhere to go yet, and the one status write
        // below comes after every half has answered - nothing can say the loop works before
        // it does, or be overwritten by a later write about an earlier state.
        showHotkeyStatus("starting — setting up the \(setup.delivery.title.lowercased())")
        let delivering = await install(setup.delivery)
        // The tap's grants from a fresh reading: this process's own answer can be the one it
        // had before the person allowed them. See `PrivacyReading`.
        let hotkey = Hotkey(for: Self.flavor, heardBy: setup.source) { [unowned self] in
            // A reading that failed is logged by `readPrivacy` and shown on the grant's row.
            switch readPrivacy() {
            case .success(let privacy): privacy.eventTapHeld
            case .failure: false
            }
        }
        let dictation = Dictation(
            capture: capture,
            transcriber: { [unowned self] in try await engine.value },
            router: Router(routes: [.dictation]),
            executor: executor(for: setup.delivery),
            report: { [unowned self] in report($0) }
        )
        listening = Listening(setup: setup, hotkey: hotkey, dictation: dictation)
        // The hotkey goes up only on a delivery that installed: a hotkey over a delivery
        // that refused would open the microphone on every press for words that go nowhere,
        // while the status line said the loop was off. Left down, it is also what lets
        // choosing the same delivery again retry the install - `take` rebuilds a loop whose
        // hotkey is not watching. [LAW:no-silent-failure]
        let hearing = delivering.flatMap {
            Result {
                try hotkey.start({ [unowned self] transition in
                    if case .began = transition { (lastDictation, lastFailure) = (nil, nil) }
                    dictation.press(transition)
                }, onLapse: { [unowned self] in report($0) })
            }.mapError { error in
                // A tap refused for want of its grants waits on them; any other refusal is
                // not something a grant can fix.
                if case KeyboardTapError.notAllowed = error {
                    LoopRefusal(awaitingGrant: "\(error); allow them in \(GuidedSetup.title(for: Self.flavor)) in this menu")
                }
                else { LoopRefusal(stringLiteral: "\(error)") }
            }
        }
        showHotkeyStatus(of: setup.source, hearing)
    }

    /// [LAW:no-silent-failure] Either half can refuse: every refusal is on the one surface
    /// this app has, in the words the user can act on.
    /// [LAW:dataflow-not-control-flow] One sentence for every pairing that works: every
    /// source feeds the same detector, which hears a hold and a tap alike.
    private func showHotkeyStatus(of source: HotkeySource, _ loop: Result<Void, LoopRefusal>) {
        switch loop {
        case .success:
            downForAGrant = false
            showHotkeyStatus("hold \(chordName(heardBy: source)), or tap it to start and again to stop")
        case .failure(let refusal):
            downForAGrant = refusal.awaitsGrant
            showHotkeyStatus("off — \(refusal.reason)")
        }
    }

    /// Makes `delivery` ready to reach the cursor as far as it can without asking anyone:
    /// this installation's input method put where macOS looks for one, registered, and -
    /// once a person has switched it on in setup - selected. Run at every adoption, which
    /// is also what keeps the input method selected across a change of hotkey source.
    ///
    /// Nothing here puts a system dialog on screen, because adoption runs at launch. The
    /// virtual keyboard's helper is first registered from its step in setup, and only an
    /// already enabled registration is refreshed here, which shows nothing; the input
    /// method is switched on from its own step. See `ask(_:)`.
    ///
    /// [LAW:no-silent-failure] An install that fails leaves a hotkey that would hear every
    /// press and insert nothing, so it comes back as a refusal for the status line.
    private func install(_ delivery: Delivery) async -> Result<Void, LoopRefusal> {
        switch delivery {
        case .virtualKeyboard:
            // An approved registration is refreshed at every adoption, which shows nothing
            // and keeps the job pointing at this copy of the app after it moves or updates.
            // One that is not approved yet is left to its step: registering is what puts
            // macOS's notice on screen. [LAW:no-silent-failure] A refresh that fails is said.
            if helperService.status == .enabled, let failure = registerKeyboardHelper() {
                log.error("keyboard helper: \(failure, privacy: .public)")
            }
            return .success(())
        case .inputMethod:
            do {
                let state = try await InputSourceInstaller(flavor: Self.flavor).install()
                log.notice("input method: \(state, privacy: .public)")
                // Stopped short of selected only where a person has yet to switch it on,
                // which is a step in setup rather than something that went wrong.
                return state.ready ? .success(()) : .failure(LoopRefusal(awaitingGrant: """
                    the input method is \(state); switch it on in \(GuidedSetup.title(for: Self.flavor)) \
                    in this menu, where macOS asks you once to allow it
                    """))
            } catch {
                log.error("input method: \(String(describing: error), privacy: .public)")
                return .failure("the input method could not be installed: \(error)")
            }
        }
    }

    /// [LAW:single-enforcer] The one place a delivery becomes the output its words reach.
    private func executor(for delivery: Delivery) -> Executor {
        switch delivery {
        case .virtualKeyboard:
            // The typist proves the target app in front before every key, so this app
            // never activates itself around a session; `LSUIElement` is what keeps its own
            // menu from taking focus.
            .guarding(keyboard: helper.keyboard, mouse: helper.mouse, interrupt: interrupt)
        case .inputMethod:
            // The words cross to this flavor's own input method, which commits them at the
            // cursor through the text input system.
            Executor(insertingThrough: InputMethodInserter(flavor: Self.flavor))
        }
    }

    /// Why half of a loop is not working, in the words the status line says it.
    /// Named apart from `Insertion.Refusal`, which is the input method's answer to an insert.
    private struct LoopRefusal: Error, ExpressibleByStringInterpolation {
        let reason: String
        /// Whether the loop is down only for a grant a person has yet to give, which is what
        /// a grant arriving later brings it back up from.
        let awaitsGrant: Bool
        init(stringLiteral reason: String) { (self.reason, awaitsGrant) = (reason, false) }
        init(awaitingGrant reason: String) { (self.reason, awaitsGrant) = (reason, true) }
    }

    /// Asked when an installation has never made `choices`' choice, which is its first
    /// launch; the delivery and the hotkey source are each asked this way, apart.
    ///
    /// The buttons are `choices` in order, and the answer is read back by that same order,
    /// so a button can never pick a choice it does not name. [LAW:one-source-of-truth]
    private func ask<Choice: CustomStringConvertible>(
        _ question: String, explaining details: String, among choices: [Choice], titled title: (Choice) -> String
    ) -> Choice {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = details + "\n\nYou can change this at any time from the menu bar."
        choices.forEach { alert.addButton(withTitle: title($0)) }
        NSApp.activate()
        let response = alert.runModal()
        let answer = choices[response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue]
        // [LAW:verifiable-goals] The question has no other trace: an agent checking that a
        // first launch asked, and what it was told, reads it here.
        log.notice("\(String(describing: Choice.self), privacy: .public): asked, answered \(answer, privacy: .public) (modal response \(response.rawValue, privacy: .public))")
        return answer
    }

    private func askForDelivery() -> Delivery {
        ask("How should \(Self.flavor.displayName) give you what you say?",
            explaining: Delivery.allCases.map { "\($0.title): \($0.explanation)" }.joined(separator: "\n\n"),
            among: Delivery.allCases, titled: \.title)
    }

    private func askForHotkeySource() -> HotkeySource {
        ask("Which hotkey should \(Self.flavor.displayName) listen for?",
            explaining: "Hold it while you speak, or tap it to start and again to stop.",
            among: HotkeySource.allCases, titled: title(of:))
    }

    /// A source as the menu and the first-launch question name it: its chord on the layout
    /// the user types on, and what macOS asks for it. [LAW:one-source-of-truth] Both halves
    /// are read off the source, so no second spelling of either is kept here.
    private func title(of source: HotkeySource) -> String {
        "\(chordName(heardBy: source)) — \(source.asks)"
    }

    /// This installation's chord for `source`, named on the layout the user types on now.
    /// Read at each use rather than kept, since the user can switch layouts at any moment.
    private func chordName(heardBy source: HotkeySource) -> String {
        let chord = Hotkey.defaultChord(for: Self.flavor, heardBy: source)
        do {
            return try Hotkey.named(chord, heardBy: source, on: KeyboardLayout.current())
        } catch {
            // [LAW:no-silent-failure] A layout that cannot be read still leaves the reader a
            // chord to press, in the spelling `held` gives every chord, and the log says why.
            log.error("keyboard layout: \(String(describing: error), privacy: .public); naming \(chord, privacy: .public) by its codes")
            return Hotkey.held(chord)
        }
    }

    // MARK: - the guided setup

    /// The guided setup, over the one list the menu and `lowtalker onboard` read.
    private lazy var setUp = SetUpWindow(
        flavor: Self.flavor,
        read: { [unowned self] in readReadiness() },
        ask: { [unowned self] in await ask($0) },
        settle: { [unowned self] in comeUpIfGranted($0) })

    /// After a choice has been made: the setup, in front of the person, when the choice
    /// brought a step they can act on - one with a button that asks macOS, or a System
    /// Settings pane. A row the old setup already needed was news then, not now, and a row
    /// nobody can act on (the assistant clears itself; the driver waits on an administrator)
    /// is not worth taking focus from the app the person is typing in; the menu's Set Up
    /// item shows both. Not on a launch that only remembers its choices.
    ///
    /// - Parameter before: the setup the choice replaced, or nil when there was none.
    private func showSetUpIfNeeded(replacing before: Setup?) {
        let actionable = readReadiness().unmet.filter { requirement in
            let row = requirement.row
            let new = before.map { !row.isNeeded(deliveries: [$0.delivery], sources: [$0.source]) } ?? true
            return new && (row.askTitle != nil || row.settingsPane != nil)
        }
        guard !actionable.isEmpty else { return }
        setUp.show()
    }

    /// Asks macOS for one requirement - the only place in the app that does, and reached
    /// only from the button a person pressed on that requirement's step. Each case raises
    /// at most one system dialog.
    ///
    /// Answers with what went wrong, for the step to show, or nil. A person declining is not
    /// something that went wrong: the next reading shows the step still unmet, with what
    /// skipping it costs. [LAW:no-silent-failure]
    private func ask(_ row: Requirement.Row) async -> String? {
        log.notice("setup: asking for \(row.rawValue, privacy: .public)")
        var failure: String?
        switch row {
        case .microphone:
            // macOS asks about the microphone once. Past that, requesting answers at once and
            // shows nothing, so a decided "no" is said here and the pane opened instead.
            switch readPrivacy().map({ $0.microphonePermission.current }) {
            case .success(.withheld(.notDetermined)):
                // Asked here, as measured on studious 2026-09-24: one dialog, naming the app.
                _ = await MicrophonePermission().request()
            case .success(.withheld(.denied)):
                failure = openPaneAfterANo(.microphone)
            case .success(.withheld(.restricted)):
                failure = "A policy on this Mac blocks the microphone."
            case .success(.granted):
                break
            case .failure(let reading):
                failure = "\(reading)"
            }
        case .inputMonitoring:
            // Checking Accessibility files the app in its list, switched off (studious,
            // 2026-09-25), and tccd answers Input Monitoring from that row: while
            // Accessibility is off, no Input Monitoring dialog can show. Allowing
            // Accessibility brings Input Monitoring with it. See `EventTapAccess`.
            switch readPrivacy().map({ $0.accessibility == true ? $0.inputMonitoring : nil }) {
            case .success(nil):
                failure = "Allow Accessibility first. Input Monitoring comes with it."
            case .success(.undecided):
                EventTapAccess.askForInputMonitoring()
            case .success(.denied):
                failure = openPaneAfterANo(.inputMonitoring)
            case .success(.granted):
                break
            case .failure(let reading):
                failure = "\(reading)"
            }
        case .accessibility:
            EventTapAccess.askForAccessibility()
        case .inputMethod:
            do { try await InputSourceInstaller(flavor: Self.flavor).switchOn() } catch {
                log.error("setup: input method: \(String(describing: error), privacy: .public)")
                failure = "\(error)"
            }
        case .keyboardHelper:
            failure = registerKeyboardHelper()
        // Nothing the app can ask for: an administrator installs the driver, and the helper
        // answers the assistant. Their steps offer no ask button, so this is never reached
        // from one; it is named rather than defaulted so a new row has to say. [LAW:no-silent-failure]
        case .driverExtension, .keyboardSetupAssistant:
            break
        }
        // A grant the chosen delivery cannot deliver without was just asked for: once it
        // reads as met, the loop is rebuilt so the delivery's install finishes the job -
        // for the input method, selecting it - whether or not the loop is up.
        if failure == nil, row.stopsDictation, let delivery = chosenDelivery, row.serves == .delivery(delivery) {
            deliveryGrantAsked = true
        }
        return failure
    }

    /// Opens a grant's System Settings pane after macOS was already answered no, and says why.
    private func openPaneAfterANo(_ row: Requirement.Row) -> String {
        row.settingsPane.map { NSWorkspace.shared.open($0) }
        return "macOS asks only once. Turn on \(Self.flavor.displayName) in the \(row.rawValue) list in System Settings."
    }

    @objc private func openSetUp() {
        setUp.show()
    }

    @objc private func chooseDelivery(_ item: NSMenuItem) {
        guard let spelling = item.representedObject as? String, let chosen = Delivery(rawValue: spelling) else {
            preconditionFailure("a delivery item carries its delivery's raw value")
        }
        take { $0.chosenDelivery = chosen }
    }

    @objc private func chooseHotkeySource(_ item: NSMenuItem) {
        guard let spelling = item.representedObject as? String, let chosen = HotkeySource(rawValue: spelling) else {
            preconditionFailure("a hotkey source item carries its source's raw value")
        }
        take { $0.chosenSource = chosen }
    }

    /// Keeps a choice made from the menu, and takes the setup it leaves down to the loop.
    ///
    /// Before `comeUp` has the microphone - not yet allowed, or refused - the choice is
    /// only kept: `comeUp` takes it up once the microphone is held, and a hotkey put up now
    /// would hear presses no capture could open for, over the status that says why.
    /// `switching` is set only by a choice taken down to a loop, which `comeUp` makes
    /// first. [LAW:no-ambient-temporal-coupling]
    ///
    /// The setup already chosen is not chosen again while its hotkey is up: rebuilding
    /// the loop would end a latched press as lapsed and throw its recording away.
    /// A hotkey that has come down has no press to lose and nothing listening, so
    /// choosing its source again is how the user starts it - and is what the status
    /// line tells them to do. Only that one case: a loop still being built has no
    /// hotkey to read yet, and letting the absence pass for a come-down would chain a
    /// second teardown and rebuild behind the first, alert and all.
    private func take(_ keep: (AppDelegate) -> Void) {
        let before = chosenSetup
        // Down is no hotkey watching and no switch building one: a loop that never came
        // up, or whose hotkey came down, but not one being rebuilt right now.
        let cameDown = listening?.hotkey.isWatching != true && switchesInFlight == 0
        keep(self)
        guard let setup = chosenSetup, setup != before || cameDown, !quitting else { return }
        Task {
            // A loop that has come up is switched; one that never did is brought up from the
            // microphone, which `comeUp` reads - so choosing again after a grant is given in
            // System Settings starts dictation, and a microphone still withheld says so.
            if switching != nil { await choose(setup) } else { await comeUp() }
            // What a setup still needs is news when the setup is new.
            if setup != before { showSetUpIfNeeded(replacing: before) }
        }
    }

    // MARK: - launch and quit

    func applicationDidFinishLaunching(_ notification: Notification) {
        show(.preparing(nil, since: launched))
        statusItem.isVisible = true
        // The Insert Dictation service, declared under NSServices in project.yml, is
        // answered by this delegate. The update makes a freshly built copy's entry
        // known without a logout.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        _ = engine
        showHotkeyStatus("starting…")
        Task { await listen() }
    }

    /// The two choices, then the loop as far as what is already granted allows, then - on
    /// the launch that made a choice - the guided setup for whatever that choice still needs.
    ///
    /// A launch asks macOS for nothing. The two questions are the app's own, and every grant
    /// is asked for from its own step in setup, after that step has said why; see `ask(_:)`.
    private func listen() async {
        // Each choice is remembered or asked on its own, so an installation that has made
        // one is asked only the other.
        let asked = chosenDelivery == nil || chosenSource == nil
        let delivery = chosenDelivery ?? askForDelivery()
        let source = chosenSource ?? askForHotkeySource()
        chosenDelivery = delivery
        chosenSource = source
        log.notice("setup: delivery \(delivery, privacy: .public), hotkey source \(source, privacy: .public)")
        await comeUp()
        if asked { showSetUpIfNeeded(replacing: nil) }
    }

    /// From the microphone up: the grant read, then capture holding it, then the hotkey in
    /// front of the keyboard, last, so no press can arrive before there is a capture to
    /// open a microphone for it. [LAW:no-ambient-temporal-coupling]
    ///
    /// Reads every grant and asks for none: a microphone not yet allowed leaves the loop
    /// down with the reason on the status line, and the setup's step is where it is asked
    /// for. Run at launch and again whenever setup may have changed what is granted.
    ///
    /// What the microphone is doing when this returns is the resting mode's to say, which
    /// is the one thing the config decides here; `AudioCapture.start` is where that is
    /// written down. [LAW:one-source-of-truth]
    ///
    /// A config that cannot be read stops the app listening rather than being answered
    /// with the defaults, which is `ConfigError`'s own rule: "there is no config" and
    /// "there is a config I could not read" are different facts, and running the second
    /// one as the first would hold or release the microphone on settings its owner never
    /// chose. The menu says what is wrong with it.
    /// [LAW:no-silent-failure]
    private func comeUp() async {
        guard let setup = chosenSetup, !quitting, !comingUp else { return }
        comingUp = true
        defer {
            comingUp = false
            settleOwedReading()
        }
        do {
            // A capture already running is left running: the microphone was held before, and
            // what came up short was the hotkey or the delivery, which `choose` rebuilds.
            // Restarting it would close and reopen an engine the resting mode holds open.
            if capture.atRest == nil {
                let config = try Config.load(for: Self.flavor).config
                try capture.start(try readPrivacy().get().microphonePermission.current.grant(), atRest: config.microphone)
                // Readied before the hotkey goes up, so the first press opens a microphone
                // already reached rather than paying for reaching one.
                capture.waitUntilReadied()
            }
        } catch {
            // Stopping is idempotent, so a grant withheld and a capture that failed to
            // start leave by one path. [LAW:dataflow-not-control-flow]
            capture.stop()
            // A microphone macOS was never asked about, or was told no, is a step in setup,
            // and the status says where it is the way the other grants' refusals do.
            let (whereToAllow, awaitsGrant) = switch error {
            case MicrophoneAuthorization.Withheld.notDetermined, MicrophoneAuthorization.Withheld.denied:
                ("; allow it in \(GuidedSetup.title(for: Self.flavor)) in this menu", true)
            // A reading that failed is retried by the next one that succeeds.
            case is PrivacyReadingFailure: ("", true)
            default: ("", false)
            }
            downForAGrant = awaitsGrant
            showHotkeyStatus("off — \(error)\(whereToAllow)")
            return
        }
        await choose(setup)
    }

    /// True while the loop is down for a grant a person has yet to give: the microphone,
    /// the event tap's two, or the input method switched on. Set by the loop's own last
    /// attempt to come up, so a loop down for anything else - a config that cannot be read,
    /// a hotkey that kept lapsing - is not restarted by a grant.
    private var downForAGrant = false
    /// True while `comeUp` runs, so readings taken meanwhile do not start a second one.
    private var comingUp = false

    /// Once every row that stops dictation is met: brings the loop up when it is down for a
    /// grant, and rebuilds a loop that is up when the chosen delivery's own grant was just
    /// asked for, so its install finishes - the input method switched back on is selected.
    ///
    /// [LAW:dataflow-not-control-flow] Decided from where things stand, not from a
    /// difference between two readings, so it holds however the grant arrived and whichever
    /// reading first sees it. [LAW:effects-at-boundaries] Reading has no effects; this is the
    /// one place a reading is acted on, called after a request, when setup comes back to the
    /// front, and when the menu opens. A reading that arrives while a switch or `comeUp` is
    /// running is owed to the moment it ends, never dropped, and never acted on while
    /// quitting. [LAW:no-ambient-temporal-coupling]
    private func comeUpIfGranted(_ readiness: Readiness) {
        guard !quitting else { return }
        // A switch or a comeUp in flight may have read the grants before this reading did,
        // so the reading is owed to the moment it ends rather than dropped.
        guard !comingUp, switchesInFlight == 0 else {
            readingOwed = true
            return
        }
        guard readiness.unmet.allSatisfy({ !$0.row.stopsDictation }), let setup = chosenSetup else { return }
        if downForAGrant {
            deliveryGrantAsked = false
            log.notice("setup: what dictation waited on is granted; bringing it up")
            Task { await comeUp() }
        } else if deliveryGrantAsked, listening?.hotkey.isWatching == true {
            deliveryGrantAsked = false
            log.notice("setup: the delivery's grant arrived; rebuilding the loop to finish installing it")
            Task { await choose(setup) }
        }
    }

    /// Set when a reading reached `comeUpIfGranted` while a switch or a comeUp was running,
    /// and settled - with a fresh reading - by whichever of them ends last.
    private var readingOwed = false

    /// Set when a request for the chosen delivery's own grant went through; cleared once the
    /// loop has been rebuilt behind it.
    private var deliveryGrantAsked = false

    /// The one place an owed reading is paid: once nothing is rebuilding the loop.
    private func settleOwedReading() {
        guard readingOwed, switchesInFlight == 0, !comingUp else { return }
        readingOwed = false
        comeUpIfGranted(readReadiness())
    }

    /// Quitting waits for the sessions, the way `lowtalker dictate` waits on its
    /// interrupt. A session holds keys down while it types and releases them on its way
    /// out, so a process that goes while one is in flight leaves a key down for macOS to
    /// repeat into whatever comes forward next; the interrupt is what cuts a long session
    /// short, and the wait is what lets it reach its release.
    /// [LAW:no-ambient-temporal-coupling] The quit has an owner, rather than a race.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitting = true
        interrupt.raise(SIGTERM)
        Task {
            // A switch in progress is let finish first, so the loop waited on is the last one.
            await switching?.value
            // The tap comes down before the wait, as at every other teardown: a press open
            // when the quit arrives is ended as lapsed and reported, rather than the app
            // going mid-utterance leaving nothing behind to say it did, and no key-down
            // landing during the wait can open a session there is no longer anyone to close.
            await listening?.hotkey.stopAndDeliver()
            // A refused wait is reported and the quit still granted: an app that cannot
            // be quit would be the worse failure of the two. [LAW:no-silent-failure]
            do { try await listening?.dictation.finish() } catch { report(.failure(error)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Off the main path from the first await: the download and the Core ML load
    /// run on WhisperKit's own threads, and only the status text comes back here.
    private func loadEngine() async throws -> WhisperKitTranscriber {
        do {
            // One operation and not two: the bundle carries a store and this loads it in
            // place — read-only, verified whole where the code signature sealed it, written
            // to never. A read-only store cannot be installed into, only confirmed and
            // loaded, so a carried store that lacks the model fails with its reason rather
            // than a permission error from a lock it could not take.
            //
            // There is deliberately no other way to reach a model from here, and a bundle
            // carrying none is a build error reported at launch rather than a download.
            // The branch that used to stand here fetched from Hugging Face when the bundle
            // carried nothing, which made a development build that had silently shipped
            // without its model look launchable and then reach the network from an app that
            // has no business doing so. Every bundle carries its model - `make app` fills
            // the store the same way scripts/sign-release does - so the case that branch
            // existed for is now a Makefile that did not run, which is worth being told
            // about in the words below. [LAW:types-are-the-program] [LAW:no-silent-failure]
            let report: @Sendable (WhisperKitTranscriber.LoadPhase) -> Void = { phase in
                Task { @MainActor in
                    let next = self.engineReadiness.reporting(phase)
                    if next != self.engineReadiness { self.show(next) }
                }
            }
            guard let carried = ModelStore.carried(by: .main) else { throw BundleCarriesNoModel() }
            let transcriber = try await WhisperKitTranscriber.loadInPlace(in: carried, phase: report)
            show(.ready(transcriber.model, after: launched.duration(to: .now)))
            return transcriber
        } catch {
            // [LAW:no-silent-failure] A model that failed to load is the one thing the
            // menu must say, since every session after this would otherwise fail
            // with no explanation on screen.
            show(.failed("\(error)"))
            throw error
        }
    }

    /// The session's own line; each action's key-up-to-acknowledged time is the
    /// typist's line beside it, under its own category. The words are private: they
    /// are what the user dictated.
    private func report(_ outcome: Result<Dictation.Session, any Error>) {
        switch outcome {
        case .success(let session):
            sessions.notice("\(session.description, privacy: .public): \(session.transcript.text, privacy: .private)")
            // Whatever left the words on the clipboard: the icon says words are waiting and
            // the Insert Dictation service can place them. [LAW:no-silent-failure]
            lastDictation = session.performed.compactMap {
                switch $0.what {
                case .copied(let text): text
                // Named rather than defaulted, so an outcome added later that also leaves
                // words on the clipboard cannot compile past this and silently never reach
                // the icon or the Service. [LAW:no-silent-failure]
                case .typed, .pressed, .clicked, .scrolled, .inserted: nil
                }
            }.last
        case .failure(let error):
            // [LAW:no-silent-failure] The words went nowhere, so the menu says why, in full:
            // only the person who dictated them reads it. A stopped route is named by what
            // stopped it; what it did first is the log's.
            lastFailure = "\((error as? RouteStopped)?.cause ?? error)"
            // The kind of failure is public and its account is not: a TypingStopped
            // names the character left half typed, which is a character the user
            // dictated. [LAW:no-silent-failure] The type alone still says what broke.
            sessions.error("session failed: \(String(describing: type(of: error)), privacy: .public) — \(String(describing: error), privacy: .private)")
        }
    }

    /// Every lapse, in the dictation log beside the sessions it damaged, so the cause of
    /// a missing sentence reads in the order it happened rather than being pieced back
    /// together from two categories by timestamp.
    ///
    /// [LAW:no-silent-failure] This is the app's only voice for a lapse that ended no
    /// press, which is the lapse that eats the beginning of the next utterance.
    ///
    /// Public in full, unlike the session line beneath it: a lapse is a count and a
    /// fixed sentence, and no part of it is anything the user dictated.
    private func report(_ lapse: KeyboardTapLapse) {
        sessions.error("\(lapse.description, privacy: .public)")
        switch lapse.response {
        // The tap is still up and the hotkey still works, so the line the menu reads is
        // still true and is left alone.
        case .rearm:
            break
        // [LAW:no-silent-failure] The hotkey is gone, and the menu is where a user looks
        // to find out what this app is doing. A log is somewhere they have no reason to
        // open, which is no use to someone whose keyboard has just started misbehaving
        // and who is trying to work out which app is doing it.
        case .comeDown:
            showHotkeyStatus("off — kept lapsing; choose a hotkey below to start it again")
        }
    }

    // MARK: - the Insert Dictation service

    /// The Insert Dictation service: the words of the last completed dictation, handed to
    /// the app that asked, which puts them at its cursor. No key is posted and nothing is
    /// pressed in that app, so it needs no grant; the app's own Services machinery does the
    /// inserting.
    ///
    /// It hands back what is ready and drives nothing: the user ends their own dictation —
    /// releasing a hold, or a second tap — and the words land in `lastDictation` the moment
    /// that session is heard, the same moment they reach the clipboard and the icon becomes
    /// one. So a service call is a read, not a wait: it cannot end a listening whose words
    /// are not yet transcribed and then return the press before it, and it cannot block the
    /// main actor the transcription needs. [LAW:no-ambient-temporal-coupling]
    ///
    /// [LAW:no-silent-failure] With no words ready it refuses with a reason rather than
    /// inserting nothing. `began` clears `lastDictation`, so a press in flight refuses until
    /// it completes rather than serving the one before it; under the virtual keyboard, where
    /// a session types rather than copies, nothing is ever left here and the service has
    /// nothing to insert, which is right — those words are already in the app.
    @objc func insertDictation(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let words = lastDictation else {
            let reason = "no dictation ready to insert — dictate first, and insert once the words are on the clipboard"
            error.pointee = reason as NSString
            log.notice("insert dictation: \(reason, privacy: .public)")
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(words, forType: .string)
        log.notice("insert dictation: returned \(words.count, privacy: .public) characters")
    }

    // MARK: - the menu

    /// What this installation's setup needs, read off this Mac now, and logged as it is read.
    ///
    /// The one reading every surface in the app draws from: the menu, the guided setup, and
    /// the question of whether setup has anything to show. Read for the setup the person
    /// chose; before a choice is made, for every choice there is.
    ///
    /// With the virtual keyboard it waits about 220ms - measured from the log timestamps,
    /// and spent almost entirely in the driver probe's subprocesses. It is paid on every read
    /// rather than kept warm in the background because a cached reading is a reading that
    /// can be stale exactly when it matters: right after the user gave the approval the
    /// menu was telling them to give. [LAW:no-ambient-temporal-coupling]
    private func readReadiness() -> Readiness {
        let (delivery, source) = shownChoices
        // The one reading no other process can take, logged raw as `SMAppService` gave
        // it. On a Mac whose helper is already approved it changes nothing a reader
        // sees, so an agent checking that the app asked at all - and that it asked about
        // the right plist - has nothing else to read back. [LAW:no-silent-failure]
        let registration = helperService.status
        log.notice("helper registration: SMAppService.Status \(registration.rawValue, privacy: .public)")
        let readiness = OnboardingProbe.readiness(
            flavor: Self.flavor,
            delivery: delivery,
            source: source,
            reader: .theApp(helperAwaitingApproval: registration == .requiresApproval, privacy: readPrivacy()),
            cli: Self.carriedCLI)
        log.notice("onboarding: \(readiness.ready ? "ready" : "not ready", privacy: .public)")
        for requirement in readiness.requirements {
            log.notice("onboarding: \(requirement.name, privacy: .public): \(requirement.reads, privacy: .public)")
        }
        return readiness
    }

    /// The app's privacy grants as they stand now, read by the carried CLI in a process of
    /// its own, because this process keeps the answers it read first. See `PrivacyReading`.
    private func readPrivacy() -> Result<PrivacyReading, PrivacyReadingFailure> {
        let (delivery, source) = shownChoices
        let checkingAccessibility = OnboardingProbe.needed(delivery: delivery, source: source).contains(.accessibility)
        let reading = Result { () throws(PrivacyReadingFailure) in
            try PrivacyReading.taken(by: Self.carriedCLI, checkingAccessibility: checkingAccessibility)
        }
        switch reading {
        case .success(let privacy): log.notice("privacy: \(privacy.line, privacy: .public)")
        case .failure(let failure): log.error("privacy: \(failure.description, privacy: .public)")
        }
        return reading
    }

    /// Everything the menu says, made here, every time, from what this Mac reads now.
    ///
    /// An `LSUIElement` app has no window to activate, so opening the menu is the moment
    /// to re-read. `menuNeedsUpdate` rather than `menuWillOpen`: AppKit calls this one
    /// before the menu is laid out, so the items are in place when it is measured.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let (delivery, source) = shownChoices
        // The rows of the setup the person chose and no other: a list of driver steps would
        // be a list of things to install for an output nobody is using.
        let readiness = readReadiness()
        comeUpIfGranted(readiness)

        // What the user's microphone is doing, on the surface the epic exists for: the
        // menu-bar indicator says the device is open and only this says why, so a lit
        // microphone on an idle Mac is either explained here or is a bug - and a dark one
        // the config asked to hold open says so here too. [LAW:no-silent-failure]
        let microphone = capture.doing
        log.notice("microphone at rest: \(microphone, privacy: .public)")

        menu.removeAllItems()
        menu.addItem(readout("Whisper model: \(engineReadiness.readout(at: .now))"))
        // A press made during the wait is not lost, and nothing else on screen says so.
        if case .preparing = engineReadiness { menu.addItem(readout("A press now is heard once the model is ready")) }
        menu.addItem(readout("Microphone: \(microphone)"))
        menu.addItem(readout("Hotkey: \(hotkeyStatus)"))
        if wordsOnClipboard { menu.addItem(readout("Your last dictation was copied to the clipboard")) }
        lastFailure.map { menu.addItem(readout("Your last dictation was not placed: \($0)")) }
        // Every requirement, met or not, and its step under it as the lines it was
        // written in - one item per line, so nothing here wraps text the requirement
        // already broke. A list that showed only what was missing would leave a reader
        // unable to tell "checked and fine" from "never checked".
        // [LAW:dataflow-not-control-flow]
        for requirement in readiness.requirements {
            menu.addItem(readout("\(requirement.name): \(requirement.reads)"))
            for line in requirement.stepLines { menu.addItem(readout("    \(line)")) }
        }
        // The way into the guided setup, always there, and saying how much is left in it.
        let left = readiness.unmet.count
        let stepsLeft = left == 0 ? "" : " (\(left) left)"
        menu.addItem(withTitle: "\(GuidedSetup.title(for: Self.flavor))\(stepsLeft)", action: #selector(openSetUp), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(readout("Delivery"))
        for choice in Delivery.allCases {
            let item = NSMenuItem(title: "    \(choice.title)", action: #selector(chooseDelivery(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = choice == delivery ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(readout("Hotkey source"))
        for choice in HotkeySource.allCases {
            let item = NSMenuItem(title: "    \(title(of: choice))", action: #selector(chooseHotkeySource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = choice == source ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        // Where every step that asks for a click sends a reader, one click closer.
        if delivery == .virtualKeyboard {
            menu.addItem(withTitle: "Open Login Items & Extensions…", action: #selector(openLoginItems), keyEquivalent: "")
        }
        menu.addItem(withTitle: "Quit \(Self.flavor.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// A line the menu says and nothing a reader can press. An item with no action is
    /// one AppKit disables on its own, which is the whole of what "readout" means here.
    private func readout(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }
}

private extension Delivery {
    /// The name a person picks it by, in the menu and in the first-launch question.
    var title: String {
        switch self {
        case .inputMethod: "Input Method"
        case .virtualKeyboard: "Virtual Keyboard"
        }
    }

    /// What it does and what it costs to install. No chord: which one is heard is the
    /// hotkey source's to say.
    var explanation: String {
        switch self {
        case .inputMethod:
            "the words are committed where your cursor is. Nothing for an administrator to approve."
        case .virtualKeyboard:
            "the words are typed where you are. Needs a driver extension and a helper, which an administrator approves once."
        }
    }
}

/// A bundle built without the model it is supposed to carry.
///
/// [LAW:no-silent-failure] Not a state this app recovers from and not one it downloads its
/// way out of: the model is put in at build time, so a bundle without one was built wrong
/// and the only thing to do about it is say so where the person running it will read it.
struct BundleCarriesNoModel: Error, CustomStringConvertible {
    var description: String {
        "this build carries no model in Contents/Resources/\(ModelStore.carriedResourceName); "
            + "it was built without one. Build it with `make app`, which puts the model in."
    }
}
