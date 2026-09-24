import AppKit
import Dictation
import Flavors
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
    /// Registering is idempotent, so it happens every time the virtual keyboard is
    /// adopted: the first lands the job in Login Items as "requires approval", where it
    /// waits for the user. Nothing is read back here. `SMAppService` answers only whether
    /// this app's own registration is approved, and that is one of two readings the
    /// helper's row needs - the other, which job actually holds the Mach service, only
    /// launchd can give. Both are taken together when the menu opens.
    private func registerKeyboardHelper() {
        do {
            try helperService.register()
        } catch {
            // [LAW:no-silent-failure] On the first registration of every install this throws
            // "Operation not permitted": smd will not bootstrap a daemon nobody has
            // approved yet. That is a normal step on the way in rather than a failure to
            // start, so it is reported here and the readout comes from what was read.
            log.notice("keyboard helper: register — \(error.localizedDescription, privacy: .public)")
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

    /// Where this installation's delivery is kept: its own defaults domain, so the two
    /// installations choose apart. [LAW:one-source-of-truth] The menu and the first-launch
    /// question write it, launch reads it, and nothing else holds a copy.
    ///
    /// Still spelled `inputMethod`, which the type no longer is, because the word on disk
    /// is every installed copy's stored answer and renaming it would ask them all again.
    private static let deliveryKey = "inputMethod"
    /// Where this installation's hotkey source is kept, beside the delivery and apart from it.
    private static let hotkeySourceKey = "hotkeySource"

    /// The delivery the user chose, or nil for an installation that has never been asked.
    /// A stored word that names no delivery reads as never asked, and the question comes
    /// back: that is the one answer to it a person can act on.
    private var chosenDelivery: Delivery? {
        get { UserDefaults.standard.string(forKey: Self.deliveryKey).flatMap(Delivery.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: Self.deliveryKey) }
    }

    /// The hotkey source the user chose, or nil for an installation that has never been
    /// asked, read the way `chosenDelivery` is.
    private var chosenSource: HotkeySource? {
        get { UserDefaults.standard.string(forKey: Self.hotkeySourceKey).flatMap(HotkeySource.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: Self.hotkeySourceKey) }
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
        await this.value
    }

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
        let hotkey = Hotkey(for: Self.flavor, heardBy: setup.source)
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
            }.mapError { LoopRefusal(stringLiteral: "\($0)") }
        }
        showHotkeyStatus(of: setup.source, hearing)
    }

    /// [LAW:no-silent-failure] Either half can refuse: every refusal is on the one surface
    /// this app has, in the words the user can act on.
    /// [LAW:dataflow-not-control-flow] One sentence for every pairing that works: every
    /// source feeds the same detector, which hears a hold and a tap alike.
    private func showHotkeyStatus(of source: HotkeySource, _ loop: Result<Void, LoopRefusal>) {
        switch loop {
        case .success: showHotkeyStatus("hold \(chordName(heardBy: source)), or tap it to start and again to stop")
        case .failure(let refusal): showHotkeyStatus("off — \(refusal.reason)")
        }
    }

    /// Makes `delivery` ready to reach the cursor: the virtual keyboard's helper registered,
    /// or this installation's input method put where macOS looks for one, registered,
    /// switched on and selected. Run at every adoption, since choosing a delivery is what
    /// installs it and both are idempotent - which is also what keeps the input method
    /// selected across a change of hotkey source.
    ///
    /// [LAW:no-silent-failure] An install that fails leaves a hotkey that would hear every
    /// press and insert nothing, so it comes back as a refusal for the status line.
    private func install(_ delivery: Delivery) async -> Result<Void, LoopRefusal> {
        switch delivery {
        case .virtualKeyboard:
            registerKeyboardHelper()
            return .success(())
        case .inputMethod:
            do {
                let state = try await InputSourceInstaller(flavor: Self.flavor).install()
                log.notice("input method: \(state, privacy: .public)")
                return .success(())
            } catch InputSourceInstallFailure.switchedOnOnlyAtNextLogin(let identifier) {
                // The copy and the registration both happened; what is left is the login.
                log.error("input method: \(identifier, privacy: .public) waits for the next login")
                return .failure("the input method is waiting for your next login: \(InputSourceInstallFailure.switchedOnOnlyAtNextLogin(identifier: identifier))")
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
        init(stringLiteral reason: String) { self.reason = reason }
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

    /// After the user has chosen a delivery: what it still needs, in front of them, when it
    /// needs anything. Not on a launch that only remembers the choice, which the menu
    /// already answers every time it opens. For the input method that is the moment a
    /// first install learns macOS wants a login before switching it on, and the person
    /// hears it then rather than at their first press. [LAW:no-silent-failure]
    private func showWhatIsMissing(for delivery: Delivery) {
        show(readiness(of: delivery), missingFrom: delivery)
    }

    /// The alert itself, from a reading already taken.
    private func show(_ readiness: Readiness, missingFrom delivery: Delivery) {
        guard !readiness.ready else { return }
        let alert = NSAlert()
        alert.informativeText = readiness.description
        switch delivery {
        case .inputMethod:
            alert.messageText = "The input method is not ready yet"
            alert.addButton(withTitle: "OK")
            NSApp.activate()
            alert.runModal()
        case .virtualKeyboard:
            alert.messageText = "The virtual keyboard needs a few steps before it can type"
            alert.addButton(withTitle: "Open Login Items & Extensions…")
            alert.addButton(withTitle: "Later")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn { openLoginItems() }
        }
    }

    /// Choosing the delivery already listening repairs it rather than switching to it;
    /// the menu's row for the input method says to do exactly this.
    @objc private func chooseDelivery(_ item: NSMenuItem) {
        guard let spelling = item.representedObject as? String, let chosen = Delivery(rawValue: spelling) else {
            preconditionFailure("a delivery item carries its delivery's raw value")
        }
        if let standing = listening?.setup, standing.delivery == chosen, listening?.hotkey.isWatching == true {
            repair(standing)
        } else {
            take { $0.chosenDelivery = chosen }
        }
    }

    /// When the listening delivery reads as not ready, sets it up again if its install can
    /// put that right - an input method deleted by hand, or switched off - and says what is
    /// still missing either way.
    ///
    /// [LAW:no-ambient-temporal-coupling] Queued behind any switch in progress and read
    /// only once it has finished, so a second click while the first repair runs finds it
    /// done and does nothing. A delivery that reads ready, or one whose missing steps only a
    /// person can take, is never torn down: a press latched open over it is left to finish.
    private func repair(_ setup: Setup) {
        let before = switching
        switching = Task {
            await before?.value
            // A choice made meanwhile supersedes this one, and so does a quit: each waits
            // behind, and a repair of what it replaces would reinstall and alert for nothing.
            // [LAW:no-ambient-temporal-coupling]
            guard !quitting, setup == chosenSetup else { return }
            var readiness = readiness(of: setup.delivery)
            guard !readiness.ready else { return }
            // Read again only after an install, the one thing here that can change it.
            if setup.delivery.installRepairsIt {
                await adopt(setup)
                readiness = self.readiness(of: setup.delivery)
            }
            guard !quitting, setup == chosenSetup else { return }
            show(readiness, missingFrom: setup.delivery)
        }
    }

    @objc private func chooseHotkeySource(_ item: NSMenuItem) {
        guard let spelling = item.representedObject as? String, let chosen = HotkeySource(rawValue: spelling) else {
            preconditionFailure("a hotkey source item carries its source's raw value")
        }
        take { $0.chosenSource = chosen }
    }

    /// Keeps a choice made from the menu, and takes the setup it leaves down to the loop.
    ///
    /// Before `listen` has the microphone - its prompt still open, or refused - the choice
    /// is only kept: `listen` takes it up once the microphone is held, and a hotkey put
    /// up now would hear presses no capture could open for, over the status that says
    /// why. `switching` is set only by a choice taken down to a loop, which `listen`
    /// makes first. [LAW:no-ambient-temporal-coupling]
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
        let cameDown = listening?.hotkey.isWatching == false
        keep(self)
        guard let setup = chosenSetup, switching != nil, setup != before || cameDown, !quitting else { return }
        Task {
            await choose(setup)
            // What a delivery still needs is news when the delivery is new, and not when
            // only the hotkey it sits behind has changed.
            if setup.delivery != before?.delivery { showWhatIsMissing(for: setup.delivery) }
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

    /// From the microphone up: the grant, then capture holding it, then the hotkey in
    /// front of the keyboard, last, so no press can arrive before there is a capture to
    /// open a microphone for it. [LAW:no-ambient-temporal-coupling] A fresh install sees
    /// the system prompt for the microphone here; macOS remembers the answer, so later
    /// launches ask nothing.
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
    private func listen() async {
        do {
            let config = try Config.load(for: Self.flavor).config
            try capture.start(try await MicrophonePermission().request().grant(), atRest: config.microphone)
            // Readied before the hotkey goes up, so the first press opens a microphone
            // already reached rather than paying for reaching one.
            capture.waitUntilReadied()
        } catch {
            // Stopping is idempotent, so a grant refused and a capture that failed to
            // start leave by one path. [LAW:dataflow-not-control-flow]
            capture.stop()
            showHotkeyStatus("off — \(error)")
            return
        }
        // Each choice is remembered or asked on its own, so an installation that has made
        // one is asked only the other.
        let asked = chosenDelivery == nil
        let delivery = chosenDelivery ?? askForDelivery()
        let source = chosenSource ?? askForHotkeySource()
        chosenDelivery = delivery
        chosenSource = source
        log.notice("setup: delivery \(delivery, privacy: .public), hotkey source \(source, privacy: .public)")
        await choose(Setup(delivery: delivery, source: source))
        if asked { showWhatIsMissing(for: delivery) }
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

    /// The input method's one row. A reading that failed is a row saying so, never an
    /// absent row. [LAW:no-silent-failure]
    private func readInputMethodReadiness() -> Readiness {
        do { return Readiness([.inputMethod(try InputSourceInstaller(flavor: Self.flavor).state(), flavor: Self.flavor)]) }
        catch { return Readiness([.unreadable(.inputMethod, error)]) }
    }

    /// What the virtual keyboard needs, read off this Mac now.
    ///
    /// The reading waits about 220ms - measured from the log timestamps, and spent almost
    /// entirely in the driver probe's subprocesses. It is paid on every read rather than
    /// kept warm in the background because a cached reading is a reading that can be
    /// stale exactly when it matters: right after the user gave the approval the menu was
    /// telling them to give. [LAW:no-ambient-temporal-coupling]
    private func readVirtualKeyboardReadiness() -> Readiness {
        // The one reading no other process can take, logged raw as `SMAppService` gave
        // it. On a Mac whose helper is already approved it changes nothing a reader
        // sees, so an agent checking that the app asked at all - and that it asked about
        // the right plist - has nothing else to read back. [LAW:no-silent-failure]
        let registration = helperService.status
        log.notice("helper registration: SMAppService.Status \(registration.rawValue, privacy: .public)")
        return OnboardingProbe.readiness(flavor: Self.flavor, approvalPending: registration == .requiresApproval)
    }

    /// What `delivery` needs, read off this Mac now. [LAW:single-enforcer] The one place a
    /// delivery is matched to its requirements, for the menu and the alert alike.
    ///
    /// The input method's one row is read here, off the installer, rather than in
    /// `OnboardingProbe`, which links no window server. Read afresh at every call, so a
    /// bundle deleted by hand reads as missing at the next menu open. Logged as it is read,
    /// the same for both deliveries.
    private func readiness(of delivery: Delivery) -> Readiness {
        let readiness = switch delivery {
        case .virtualKeyboard:
            readVirtualKeyboardReadiness()
        case .inputMethod:
            readInputMethodReadiness()
        }
        log.notice("onboarding: \(readiness.ready ? "ready" : "not ready", privacy: .public)")
        for requirement in readiness.requirements {
            log.notice("onboarding: \(requirement.name, privacy: .public): \(requirement.reads, privacy: .public)")
        }
        return readiness
    }

    /// Everything the menu says, made here, every time, from what this Mac reads now.
    ///
    /// An `LSUIElement` app has no window to activate, so opening the menu is the moment
    /// to re-read. `menuNeedsUpdate` rather than `menuWillOpen`: AppKit calls this one
    /// before the menu is laid out, so the items are in place when it is measured.
    func menuNeedsUpdate(_ menu: NSMenu) {
        // The kept choices while nothing listens yet, so a choice made then is shown as made.
        let delivery = listening?.setup.delivery ?? chosenDelivery
        let source = listening?.setup.source ?? chosenSource
        // The chosen delivery's requirements and no other's: a list of driver steps under the
        // input method would be a list of things to install for an output nobody is using.
        let requirements = delivery.map { readiness(of: $0).requirements } ?? []

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
        for requirement in requirements {
            menu.addItem(readout("\(requirement.name): \(requirement.reads)"))
            for line in requirement.stepLines { menu.addItem(readout("    \(line)")) }
        }
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
    /// Whether installing it again can put right what its requirements say is missing. The
    /// input method's install copies, registers and switches on; every unmet row of the
    /// virtual keyboard waits on a person - an install, an approval, a restart.
    var installRepairsIt: Bool {
        switch self {
        case .inputMethod: true
        case .virtualKeyboard: false
        }
    }

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
