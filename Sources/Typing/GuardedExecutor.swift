import Keystrokes
import LowTalkerCore
import Pointing

extension Executor {
    /// The executor as every surface that performs on real devices builds it: each
    /// keystroke and each pointer report refused once the operator has interrupted or
    /// the target app has left the front.
    ///
    /// [LAW:one-source-of-truth] The app, `lowtalker act` and `lowtalker dictate` all
    /// answer "may this key still be pressed" and they must answer it the same way;
    /// three spellings of the guard would be three answers, drifting apart the first
    /// time one of them learns something. What legitimately differs between them -
    /// which devices, whose interrupt, which chords the tap owns - crosses this one
    /// boundary as values. [LAW:dataflow-not-control-flow]
    ///
    /// Named for the guard rather than for the helper so that the sudo path can build
    /// it over the driver directly: `Typing` still knows nothing about XPC.
    /// [LAW:composability]
    public static func guarding(
        keyboard: any KeyPress,
        mouse: any Pointing,
        interrupt: Interrupt,
        hotkeys: Set<KeyChord>
    ) -> Executor {
        Executor(
            keyboard: { GuardedKeyboard(keyboard: keyboard, interrupt: interrupt, screen: TargetApp(bundleID: $0, interrupt: interrupt)) },
            mouse: {
                // The pointer's own target: the same app, read again, so a click and a
                // keystroke into one app never disagree about whether it is still there.
                let target = TargetApp(bundleID: $0, interrupt: interrupt)
                return Pointer(
                    mouse: GuardedMouse(pointing: mouse, interrupt: interrupt, screen: target),
                    cursor: Pointer.screenCursor,
                    locate: target.frame(ofRole:titled:)
                )
            },
            hotkeys: hotkeys
        )
    }
}
