import ApplicationServices
import CoreGraphics

/// The two grants an event tap on the keyboard needs: Input Monitoring to read the keys,
/// and Accessibility to hold the chord back from the app in front.
///
/// Accessibility normally brings Input Monitoring with it, and an explicit "no" to Input
/// Monitoring still deafens the tap. Measured on studious (macOS 15.0.1, 2026-09-24)
/// with a throwaway app that made this tap and posted its own key through it. With
/// Accessibility held and no Input Monitoring answer on record, `CGPreflightListenEventAccess`
/// read true, tccd answered `kTCCServiceListenEvent` from the Accessibility grant, and the
/// key arrived with no dialog. With Input Monitoring switched off it read false, and the tap
/// was still created, without an error, but nothing reached it. So both are read before a
/// tap, and Accessibility is asked for first.
///
/// [LAW:effects-at-boundaries] Reading and asking are apart on purpose. Reading never puts
/// anything on screen, so anything may read at any moment - a launch, a menu opening, a
/// tap about to be created. Asking raises macOS's own dialog, so it is only ever done
/// because a person pressed a button that said it would.
public enum EventTapAccess {
    /// Whether this process may read the keyboard. Never prompts.
    public static var inputMonitoring: Bool { CGPreflightListenEventAccess() }

    /// Whether this process may act on other apps' input. Never prompts.
    public static var accessibility: Bool { AXIsProcessTrusted() }

    /// Both, which is what a tap needs before it is created: a tap created without them
    /// is how macOS comes to raise its dialog on its own, unasked.
    public static var held: Bool { inputMonitoring && accessibility }

    /// Raises macOS's Accessibility dialog. The option key is spelled out rather than read
    /// from `kAXTrustedCheckOptionPrompt`, a C global Swift 6 will not read from a
    /// nonisolated context; the string is that constant's documented value.
    public static func askForAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}
