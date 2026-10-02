import AppKit
import ArgumentParser
import Identity
import InputSource
import LowTalkerCore

/// Watches the hotkey from the command line, so a hold and a tap can each be seen without
/// the app.
///
/// It hears through the input method, as the app does, so it is refused while the app is
/// running: only one process can hear on the hotkey port.
struct HotkeyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hotkey",
        abstract: "Print each press of the hotkey, hold or tap, until interrupted."
    )

    // Whole milliseconds, for the same reason as `mic watch --interval`.
    @Option(help: "Milliseconds a press must stay under to be a tap.")
    var tapThreshold: Int = Int(Hotkey.defaultTapThreshold / .milliseconds(1))

    func validate() throws {
        guard tapThreshold > 0 else { throw ValidationError("--tap-threshold must be positive.") }
    }

    @MainActor
    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let config = try Config.load().config
        let hotkey = Hotkey(listeningFor: config, tapThreshold: .milliseconds(tapThreshold))
        try hotkey.start { transition in
            // The press's own stamp beside the moment it was handled, so a stamp not on the
            // uptime clock shows as a gap nobody could press through.
            switch transition {
            case .began(_, let moment): print("began, delivered \(Int((HostTime.now - moment) / .microseconds(1))) us after its stamp")
            case .ended(_, let ending): print("ended (\(ending))")
            }
        }
        // Named from the config the hotkey was built from rather than spelled here.
        // [LAW:one-source-of-truth]
        print("watching \(Hotkey.named(in: config))")
        // The input method is handed keys only while its source is the one in use, so a watch
        // over any other source would print nothing and look like a hotkey that is broken.
        // [LAW:no-silent-failure]
        let selected = InstalledInputMethod.isSelected()
        print("\(AppIdentity.displayName) \(selected ? "is" : "is not; nothing is heard until it is") the selected input source")
        // The port's messages are handed to the main queue, which a command with no loop never
        // drains. The app has no Dock icon and no menu: it exists to be delivered to.
        NSApplication.shared.setActivationPolicy(.prohibited)
        withExtendedLifetime(hotkey) { NSApplication.shared.run() }
    }
}
