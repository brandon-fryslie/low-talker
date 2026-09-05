import AppKit
import LowTalkerCore
import os

/// The menu-bar agent. `LSUIElement` keeps it out of the Dock, so the status item
/// is the app's only surface; the delegate exists to install it and to start the
/// model loading the moment the app is up.
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

    /// The menu line that says what the engine is doing. Disabled: it is a readout,
    /// not a command.
    private let engineItem: NSMenuItem = {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }()

    /// The same readout in the unified log, where `log show` can time it: a menu
    /// nobody has open is no way to measure a launch.
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "engine")

    /// [LAW:one-source-of-truth] Every engine status passes through here, so the
    /// menu and the log never tell different stories.
    private func showEngineStatus(_ status: String) {
        engineItem.title = "Whisper model: \(status)"
        log.info("model: \(status, privacy: .public)")
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
        statusItem.isVisible = true
        // A fresh install sees the system prompt here; macOS remembers the answer, so
        // later launches ask nothing. Showing the answer in the status item is
        // low-app-3sp.1's work.
        Task { _ = await MicrophonePermission().request() }
        showEngineStatus("checking…")
        engine = Task { try await loadEngine() }
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

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(engineItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit low-talker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }
}
