import AppKit
import Dictation
import KeyboardService
import LowTalkerCore
import ServiceManagement
import Signals
import Typing
import os

/// The menu-bar agent. `LSUIElement` keeps it out of the Dock, so the status item
/// is the app's only surface; the delegate exists to install it, to start the model
/// loading the moment the app is up, and to hand the loop its microphone, engine and
/// keyboard.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // [LAW:no-ambient-temporal-coupling] NSStatusBar is only usable once the
    // application object exists, which is after this delegate is allocated. Lazy
    // creation ties the item's lifetime to first use instead of to an optional that
    // every later reader would have to unwrap.
    private lazy var statusItem: NSStatusItem = {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "low-talker")
        item.menu = makeMenu()
        return item
    }()

    /// A menu line that is a readout, not a command.
    private static func readout() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// What the engine is doing.
    private let engineItem = readout()
    /// Whether the hotkey is being watched, or why not.
    private let hotkeyItem = readout()
    /// Where the keyboard helper stands with launchd. The one action a user has on it,
    /// the approval, is theirs alone to give.
    private let helperItem = readout()

    /// The same readouts in the unified log, where `log show` can time them: a menu
    /// nobody has open is no way to measure a launch.
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "engine")
    /// One line per press: what was heard, how long after key-up, and what was typed.
    private let sessions = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "dictation")

    /// [LAW:one-source-of-truth] Every engine status passes through here, so the
    /// menu and the log never tell different stories.
    private func showEngineStatus(_ status: String) {
        engineItem.title = "Whisper model: \(status)"
        log.info("model: \(status, privacy: .public)")
    }

    private func showHotkeyStatus(_ status: String) {
        hotkeyItem.title = "Hotkey: \(status)"
        log.notice("hotkey: \(status, privacy: .public)")
    }

    /// The root keyboard helper, registered from the bundle's own launchd plist.
    ///
    /// Registering is idempotent, so it happens on every launch: the first one lands the
    /// job in Login Items as "requires approval", where it waits for the user, and every
    /// later one reads back where it stands. What is read is what is shown; nothing here
    /// assumes the click happened. [LAW:no-silent-failure] Walking the user through the
    /// approval is onboarding's job (low-keyboard-3ti.7); this shows the state and opens
    /// the pane.
    private func registerKeyboardHelper() {
        let service = SMAppService.daemon(plistName: "\(Helper.launchdLabel).plist")
        // [LAW:dataflow-not-control-flow] On the first launch of every install register()
        // throws "Operation not permitted": smd will not bootstrap a daemon nobody has
        // approved yet. So the throw is not the readout; the status is, and it is read
        // whether or not the call threw. The throw goes to the log as what smd said.
        do {
            try service.register()
        } catch {
            log.notice("keyboard helper: register — \(error.localizedDescription, privacy: .public)")
        }
        showHelperStatus(Self.describe(service.status))
    }

    private func showHelperStatus(_ status: String) {
        helperItem.title = "Keyboard helper: \(status)"
        log.notice("keyboard helper: \(status, privacy: .public)")
    }

    /// Every state SMAppService can report, in the words a user can act on.
    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "enabled"
        case .requiresApproval: "waiting for approval in Login Items & Extensions"
        case .notRegistered: "not registered"
        case .notFound: "not found in the app bundle"
        @unknown default: "in a state this build does not know (\(status.rawValue))"
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
        statusItem.isVisible = true
        showEngineStatus("checking…")
        _ = engine
        registerKeyboardHelper()
        showHotkeyStatus("starting…")
        Task { await listen() }
    }

    /// From the microphone up: the grant, then capture on it, then the tap in front of
    /// the keyboard, last, so no press can arrive before there is audio behind it.
    /// [LAW:no-ambient-temporal-coupling] A fresh install sees the system prompt for
    /// the microphone here; macOS remembers the answer, so later launches ask nothing.
    private func listen() async {
        do {
            try capture.start(try await MicrophonePermission().request().grant())
            try hotkey.start { [unowned self] in dictation.press($0) }
            showHotkeyStatus("hold \(Hotkey.defaultChord.spelled) to dictate")
        } catch {
            // Whatever got as far as starting is put back: a tap that failed after
            // capture began would otherwise leave the microphone open with nothing
            // reading it, under a menu saying dictation is off. Stopping is idempotent,
            // so both failures leave by this one path. [LAW:dataflow-not-control-flow]
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

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(engineItem)
        menu.addItem(hotkeyItem)
        menu.addItem(helperItem)
        menu.addItem(withTitle: "Approve the keyboard helper in Login Items…", action: #selector(openLoginItems), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit low-talker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }
}
