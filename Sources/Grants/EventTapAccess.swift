import ApplicationServices

/// The one grant an event tap on the keyboard needs: Accessibility, which covers both
/// reading the keys and holding the chord back from the app in front.
///
/// Accessibility alone is enough, measured on studious (macOS 15.0.1, 2026-09-24): a
/// throwaway app holding Accessibility and no Input Monitoring row created an active
/// (`.defaultTap`) keyboard tap. tccd did consult `kTCCServiceListenEvent` for it, and
/// answered allowed from the Accessibility grant, with no dialog. With neither grant, both
/// read as not allowed. So Input Monitoring is never asked for.
///
/// [LAW:effects-at-boundaries] Reading and asking are apart on purpose. Reading never puts
/// anything on screen, so anything may read at any moment - a launch, a menu opening, a
/// tap about to be created. Asking raises macOS's own dialog, so it is only ever done
/// because a person pressed a button that said it would.
public enum EventTapAccess {
    /// Whether this process may act on other apps' input, which is what a tap needs before
    /// it is created: a tap created without it is how macOS comes to raise its dialog on
    /// its own, unasked. Never prompts.
    public static var accessibility: Bool { AXIsProcessTrusted() }

    /// Raises macOS's Accessibility dialog. The option key is spelled out rather than read
    /// from `kAXTrustedCheckOptionPrompt`, a C global Swift 6 will not read from a
    /// nonisolated context; the string is that constant's documented value.
    public static func askForAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}
