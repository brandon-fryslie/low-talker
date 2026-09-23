import AppKit
import ArgumentParser
import Flavors
import Foundation
import KeyboardLayout
import LowTalkerCore
import Typing

/// Watches this installation's hotkey from the command line, so a hold, a tap, and the
/// key no longer reaching the frontmost app can each be seen before the app is wired.
///
/// The CLI is not the app: macOS charges a terminal command's event tap to the
/// terminal, so it needs Input Monitoring and Accessibility for the terminal.
struct HotkeyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hotkey",
        abstract: "Print each press of this installation's hotkey, hold or tap, until interrupted."
    )

    @OptionGroup var installation: FlavorOption

    @Option(help: "How to hear the hotkey: eventTap, needing Input Monitoring, or registeredHotKey, needing nothing.")
    var heardBy: HotkeySource = .eventTap

    // Whole milliseconds, for the same reason as `mic watch --interval`.
    @Option(help: "Milliseconds a press must stay under to be a tap.")
    var tapThreshold: Int = Int(Hotkey.defaultTapThreshold / .milliseconds(1))

    func validate() throws {
        guard tapThreshold > 0 else { throw ValidationError("--tap-threshold must be positive.") }
    }

    @MainActor
    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let chord = Hotkey.defaultChord(for: installation.flavor, heardBy: heardBy)
        let hotkey = Hotkey(for: installation.flavor, heardBy: heardBy, tapThreshold: .milliseconds(tapThreshold))
        try hotkey.start { transition in
            // The press's own stamp beside the moment it was handled, so a tap whose
            // clock is not the uptime clock shows as a gap nobody could press through.
            switch transition {
            case .began(_, let moment): print("began, delivered \(Int((HostTime.now - moment) / .microseconds(1))) us after its stamp")
            case .ended(_, let ending): print("ended (\(ending))")
            }
        } onLapse: { lapse in
            print("\(lapse)")
            // Nothing below this watches for anything else, so a tap that has come down
            // leaves a run loop spinning over a keyboard it can no longer hear. Ending
            // here says so, and non-zero says it to whatever ran this.
            // [LAW:no-silent-failure]
            if case .comeDown = lapse.response { Foundation.exit(1) }
        }
        // Named from the chord rather than spelled here, because the two installations
        // do not watch the same keys, and in the app's words for how it is heard.
        // [LAW:one-source-of-truth]
        print("watching \(Hotkey.named(chord, heardBy: heardBy, on: try KeyboardLayout.current()))")
        // A registered hot key reaches its owner through the application's event loop, and
        // a command with no loop registers it and hears nothing. The tap needs no loop but
        // runs under this one the same, so both are watched one way. The app has no Dock
        // icon and no menu: it exists to be delivered to.
        NSApplication.shared.setActivationPolicy(.prohibited)
        withExtendedLifetime(hotkey) { NSApplication.shared.run() }
    }
}

extension HotkeySource: ExpressibleByArgument {}
