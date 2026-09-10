import Keystrokes

/// The keyboard one character is typed on: keys that go down, a release that takes them
/// all back up, and the refusal that guards every one of them.
///
/// [LAW:effects-at-boundaries] Posting a key is an effect against the driver and the
/// refusal reads the window server, so both sit behind this seam - which is what lets a
/// test throw at the third keystroke of a four-keystroke character and read back the
/// score the run would have reported, without a driver or an app in front.
///
/// Main-actor, because the refusal reads which app is in front and that is a question
/// only the main actor may ask. The keys are awaited rather than returned from: each one
/// waits for the far side's acknowledgement, and a wait held on the main actor is a wait
/// the hotkey's tap cannot be heard through.
@MainActor
public protocol Keyboard {
    /// Throws rather than let the next keystroke be posted: the operator interrupted, or
    /// the target app is no longer frontmost. One member and not two, because a keystroke
    /// that must not be posted and a keystroke that fails to post are the same event to
    /// everything downstream. [LAW:one-type-per-behavior]
    func check() throws
    func down(_ usage: Usage) async throws
    func releaseAll() async throws
}

/// A keyboard, refusing any keystroke this run has lost the right to post.
/// [LAW:decomposition] The three things a keystroke depends on - the device, the
/// operator's interrupt, and the app in front - meet here and nowhere else, so `Scribe`
/// presses keys without knowing what a window server is.
public struct GuardedKeyboard: Keyboard {
    public let keyboard: any KeyPress
    public let queue: DeviceQueue
    public let interrupt: Interrupt
    public let screen: TargetApp

    public init(keyboard: any KeyPress, queue: DeviceQueue, interrupt: Interrupt, screen: TargetApp) {
        self.keyboard = keyboard
        self.queue = queue
        self.interrupt = interrupt
        self.screen = screen
    }

    public func check() throws {
        try interrupt.check()
        try screen.requireFrontmost()
    }

    public func down(_ usage: Usage) async throws { try await queue.run { [keyboard] in try keyboard.down(usage) } }
    public func releaseAll() async throws { try await queue.run { [keyboard] in try keyboard.releaseAll() } }
}
