import Foundation
import Keystrokes

/// What crosses the privilege boundary: a key goes down, and every key comes up.
///
/// The driver extension takes commands from root alone, so the process that owns the
/// device is not the process that decides what to type. This protocol is the whole of
/// what passes between them, and it is deliberately the smallest thing that can work.
///
/// **It cannot express text, and that is the point.** [LAW:types-are-the-program] macOS
/// turns a HID usage into a character using the console user's keyboard layout, and Text
/// Input Sources answers per process: with this Mac switched to Dvorak, the console user
/// is told `com.apple.keylayout.Dvorak` and the same call under `sudo` is told
/// `com.apple.keylayout.US`. A helper handed text would look up the keys with root's
/// layout and type something else entirely - measured, and every check still passed,
/// because the daemon acknowledged every report and the screen held what had been typed.
/// A helper that cannot be handed text cannot make that mistake.
///
/// **One report per call, and the client decides when.** The daemon acknowledges reports
/// the driver then drops: twelve 500-character runs, each report awaited, six of which
/// landed fewer keys than were acknowledged - as few as 469 of 500. The only delivery
/// receipt is the event tap, which runs in the user's session and not here. So a method
/// shaped `type(_ text: String)` would swallow a whole burst inside the helper, which has
/// no way to observe the loss and would answer "typed" to a client that got 608
/// characters. The pacing lives with the process that can see what landed.
///
/// **The focus check does not cross.** Which app is frontmost, and whether the operator
/// interrupted, are facts of the user's session that a root daemon cannot read. They stay
/// on the client, which is why this carries no "type into" argument: the helper types
/// wherever the keyboard is pointed, exactly as hardware does, and deciding that is the
/// client's job. [LAW:one-way-deps]
@objc public protocol KeyboardService {
    /// Holds `usage` down, and answers when the daemon has acknowledged the report.
    ///
    /// The reply is what makes the client's pacing possible, so it is not a fire-and-
    /// forget: `error` is nil when the report was acknowledged and carries the refusal
    /// otherwise. NSXPC has no throwing form, so the failure is the argument.
    func down(usage: UInt16, reply: @escaping (Error?) -> Void)

    /// Every key up, which is what a report of nothing held says.
    func releaseAll(reply: @escaping (Error?) -> Void)
}

/// The Mach service the helper answers on, and the launchd job that owns it.
///
/// [LAW:one-source-of-truth] One string, named once. It appears in the plist, in the
/// helper's listener, and in every client's connection, and a copy of it in any of those
/// is a way for three things to disagree about where the keyboard is.
public enum Helper {
    public static let machServiceName = "com.lowtalker.keyboardd"
    public static let launchdLabel = machServiceName
}
