import AppKit
import Dictation
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
/// keyboard.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // [LAW:no-ambient-temporal-coupling] NSStatusBar is only usable once the
    // application object exists, which is after this delegate is allocated. Lazy
    // creation ties the item's lifetime to first use instead of to an optional that
    // every later reader would have to unwrap.
    private lazy var statusItem: NSStatusItem = {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "low-talker")
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
    /// at the moment the menu opens. Launch sets both before it returns, so no menu can
    /// open on an empty string.
    private var engineStatus = ""
    private var hotkeyStatus = ""

    /// The same readouts in the unified log, where `log show` can time them: a menu
    /// nobody has open is no way to measure a launch, and no way for an agent to check
    /// what the app is showing without a screen. [LAW:verifiable-goals]
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "engine")
    /// One line per press: what was heard, how long after key-up, and what was typed.
    private let sessions = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "dictation")

    /// The helper's registration, from the bundle's own launchd plist. One instance,
    /// because registering and asking where the registration stands are two questions
    /// about one record. [LAW:one-source-of-truth]
    private let helperService = SMAppService.daemon(plistName: "\(Helper.launchdLabel).plist")

    /// [LAW:one-source-of-truth] Every engine status passes through here, so the
    /// menu and the log never tell different stories.
    private func showEngineStatus(_ status: String) {
        engineStatus = status
        log.info("model: \(status, privacy: .public)")
    }

    private func showHotkeyStatus(_ status: String) {
        hotkeyStatus = status
        log.notice("hotkey: \(status, privacy: .public)")
    }

    /// The root keyboard helper, registered from the bundle's own launchd plist.
    ///
    /// Registering is idempotent, so it happens on every launch: the first one lands the
    /// job in Login Items as "requires approval", where it waits for the user. Nothing is
    /// read back here. `SMAppService` answers only whether this app's own registration is
    /// approved, and that is one of two readings the helper's row needs - the other,
    /// which job actually holds the Mach service, only launchd can give. Both are taken
    /// together when the menu opens.
    private func registerKeyboardHelper() {
        do {
            try helperService.register()
        } catch {
            // [LAW:no-silent-failure] On the first launch of every install this throws
            // "Operation not permitted": smd will not bootstrap a daemon nobody has
            // approved yet. That is a normal step on the way in rather than a failure to
            // start, so it is reported here and the readout comes from what was read.
            log.notice("keyboard helper: register — \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// The chords the tap listens for and the typist refuses to press, named once.
    /// [LAW:one-source-of-truth] Two spellings would be a hotkey the typist could type.
    private static let chords: Set<KeyChord> = [Hotkey.defaultChord]

    private let hotkey = Hotkey(chords: chords)
    private let capture = AudioCapture()
    /// Kept for the app's life so the XPC connection to the helper stays open: launchd
    /// starts the job on the first call, and that is a cost to pay once, not per press.
    private let helper = HelperConnection()
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

    /// The loop, over the real microphone, engine and keyboard. The typist proves the
    /// target app in front before every key, so this app never activates itself around
    /// a session; `LSUIElement` is what keeps its own menu from taking focus.
    private lazy var dictation = Dictation(
        capture: capture,
        transcriber: { [unowned self] in try await engine.value },
        router: Router(routes: [.dictation]),
        executor: .guarding(keyboard: helper.keyboard, mouse: helper.mouse, interrupt: interrupt, hotkeys: Self.chords),
        report: { [unowned self] in report($0) }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        showEngineStatus("checking…")
        statusItem.isVisible = true
        _ = engine
        registerKeyboardHelper()
        showHotkeyStatus("starting…")
        Task { await listen() }
    }

    /// From the microphone up: the grant, then capture holding it, then the tap in front
    /// of the keyboard, last, so no press can arrive before there is a capture to open a
    /// microphone for it. [LAW:no-ambient-temporal-coupling] A fresh install sees the
    /// system prompt for the microphone here; macOS remembers the answer, so later
    /// launches ask nothing.
    ///
    /// Nothing is listening when this returns. `capture.start` takes the grant and
    /// watches the input device; the microphone itself opens on a press and shuts on the
    /// release, which is what keeps the menu-bar indicator a record of use rather than of
    /// how long the app has been running - unless the config asks for it to be held open,
    /// which is the one thing that can make this app hold the device at rest.
    ///
    /// A config that cannot be read stops the app listening rather than being answered
    /// with the defaults, which is `ConfigError`'s own rule: "there is no config" and
    /// "there is a config I could not read" are different facts, and running the second
    /// one as the first would hold or release the microphone on settings its owner never
    /// chose. The menu says which file and what is wrong with it.
    /// [LAW:no-silent-failure]
    private func listen() async {
        do {
            let config = try Config.load().config
            try capture.start(try await MicrophonePermission().request().grant(), atRest: config.microphone)
            try hotkey.start { [unowned self] in dictation.press($0) } onLapse: { [unowned self] in report($0) }
            showHotkeyStatus("hold \(Hotkey.defaultChord.spelled) to dictate")
        } catch {
            // Whatever got as far as starting is put back: a tap that failed after
            // capture began would otherwise leave capture holding the grant and watching
            // the device with nothing able to press, under a menu saying dictation is off.
            // Stopping is idempotent, so both failures leave by this one path.
            // [LAW:dataflow-not-control-flow]
            capture.stop()
            // [LAW:no-silent-failure] An app that cannot listen must say so on the
            // one surface it has, in the words the user can act on.
            showHotkeyStatus("off — \(error)")
        }
    }

    /// Quitting waits for the sessions, the way `lowtalker dictate` waits on its
    /// interrupt. A session holds keys down while it types and releases them on its way
    /// out, so a process that goes while one is in flight leaves a key down for macOS to
    /// repeat into whatever comes forward next; the interrupt is what cuts a long session
    /// short, and the wait is what lets it reach its release.
    /// [LAW:no-ambient-temporal-coupling] The quit has an owner, rather than a race.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        interrupt.raise(SIGTERM)
        Task {
            // A refused wait is reported and the quit still granted: an app that cannot
            // be quit would be the worse failure of the two. [LAW:no-silent-failure]
            do { try await dictation.finish() } catch { report(.failure(error)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Off the main path from the first await: the download and the Core ML load
    /// run on WhisperKit's own threads, and only the status text comes back here.
    private func loadEngine() async throws -> WhisperKitTranscriber {
        do {
            let store = try ModelStore.applicationSupport()
            let transcriber = try await WhisperKitTranscriber.load(from: store) { phase in
                Task { @MainActor in self.showEngineStatus(phase.description) }
            }
            showEngineStatus("ready (\(transcriber.model))")
            return transcriber
        } catch {
            // [LAW:no-silent-failure] A model that failed to load is the one thing the
            // menu must say, since every session after this would otherwise fail
            // with no explanation on screen.
            showEngineStatus("failed — \(error)")
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
        case .failure(let error):
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
    }

    // MARK: - the menu

    /// Everything the menu says, made here, every time, from what this Mac reads now.
    ///
    /// This is the ticket's "re-read on activation until both hold": an `LSUIElement` app
    /// has no window to activate, so opening the menu is the moment. The reading is taken
    /// on this thread, and the menu waits about 220ms for it - measured here from the log
    /// timestamps, and spent almost entirely in the driver probe's subprocesses. It is
    /// paid on open rather than kept warm in the background because a cached reading is a
    /// reading that can be stale exactly when it matters: right after the user gave the
    /// approval this menu was telling them to give. [LAW:no-ambient-temporal-coupling]
    ///
    /// `menuNeedsUpdate` rather than `menuWillOpen`: AppKit calls this one before the
    /// menu is laid out, so the items are in place when it is measured.
    func menuNeedsUpdate(_ menu: NSMenu) {
        // The one reading no other process can take, logged raw as `SMAppService` gave
        // it. On a Mac whose helper is already approved it changes nothing a reader
        // sees, so an agent checking that the app asked at all - and that it asked about
        // the right plist - has nothing else to read back. [LAW:no-silent-failure]
        let registration = helperService.status
        log.notice("helper registration: SMAppService.Status \(registration.rawValue, privacy: .public)")

        let readiness = OnboardingProbe.readiness(approvalPending: registration == .requiresApproval)
        log.notice("onboarding: \(readiness.ready ? "ready" : "not ready", privacy: .public)")
        for requirement in readiness.requirements {
            log.notice("onboarding: \(requirement.name, privacy: .public): \(requirement.reads, privacy: .public)")
        }

        // What the user's microphone is doing between presses, on the surface the epic
        // exists for: the menu-bar indicator says the device is open and only this says
        // why, so a lit microphone on an idle Mac is either explained here or is a bug.
        // [LAW:no-silent-failure]
        let microphone = capture.atRest.map(String.init(describing:)) ?? "not being captured"
        log.notice("microphone at rest: \(microphone, privacy: .public)")

        menu.removeAllItems()
        menu.addItem(readout("Whisper model: \(engineStatus)"))
        menu.addItem(readout("Microphone: \(microphone)"))
        menu.addItem(readout("Hotkey: \(hotkeyStatus)"))
        // Every requirement, met or not, and its step under it as the lines it was
        // written in - one item per line, so nothing here wraps text the requirement
        // already broke. A list that showed only what was missing would leave a reader
        // unable to tell "checked and fine" from "never checked".
        // [LAW:dataflow-not-control-flow]
        for requirement in readiness.requirements {
            menu.addItem(readout("\(requirement.name): \(requirement.reads)"))
            for line in requirement.stepLines { menu.addItem(readout("    \(line)")) }
        }
        menu.addItem(.separator())
        // Where every step that asks for a click sends a reader, one click closer.
        menu.addItem(withTitle: "Open Login Items & Extensions…", action: #selector(openLoginItems), keyEquivalent: "")
        menu.addItem(withTitle: "Quit low-talker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// A line the menu says and nothing a reader can press. An item with no action is
    /// one AppKit disables on its own, which is the whole of what "readout" means here.
    private func readout(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }
}
