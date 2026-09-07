import AppKit
import KeyboardService
import LowTalkerCore
import Onboarding
import ServiceManagement
import os

/// The menu-bar agent. `LSUIElement` keeps it out of the Dock, so the status item
/// is the app's only surface; the delegate exists to install it and to start the
/// model loading the moment the app is up.
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

    /// What the engine is doing. The one thing in the menu that cannot be read on
    /// demand: it arrives from the load's own callbacks, so it is held here while
    /// everything else is read at the moment the menu opens. Launch sets it through
    /// `showEngineStatus` before the status item is ever visible.
    private var engineStatus = ""

    /// The same readouts in the unified log, where `log show` can time them: a menu
    /// nobody has open is no way to measure a launch, and no way for an agent to check
    /// what the app is showing without a screen. [LAW:verifiable-goals]
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "engine")

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

    /// The engine, from the moment launch starts loading it. Awaiting the task is how
    /// a session gets the transcriber; a task still running is the app's "still
    /// loading" state, held here rather than inside the engine.
    ///
    /// [LAW:no-ambient-temporal-coupling] Nothing can call the transcriber before it
    /// is resident: the only handle is the task, and the task yields the value only
    /// when the initializer has returned.
    private var engine: Task<WhisperKitTranscriber, any Error>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        showEngineStatus("checking…")
        statusItem.isVisible = true
        // A fresh install sees the system prompt here; macOS remembers the answer, so
        // later launches ask nothing. Showing the answer in the status item is
        // low-app-3sp.1's work.
        Task { _ = await MicrophonePermission().request() }
        engine = Task { try await loadEngine() }
        registerKeyboardHelper()
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

        menu.removeAllItems()
        menu.addItem(readout("Whisper model: \(engineStatus)"))
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
