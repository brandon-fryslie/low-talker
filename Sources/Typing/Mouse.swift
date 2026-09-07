import Pointing

/// The mouse one click is made on: a button that goes down, a release that takes them all
/// back up, motion, the wheel, and the refusal that guards every one of them.
///
/// [LAW:effects-at-boundaries] Posting a report is an effect against the driver and the
/// refusal reads the window server, so both sit behind this seam - which is what lets a
/// test drive a pointer across a screen of its own, with acceleration of its own, and read
/// back every report it posted.
///
/// Main-actor, because the refusal reads which app is in front and that is a question
/// only the main actor may ask.
@MainActor
public protocol Mouse {
    /// Throws rather than let the next report be posted: the operator interrupted, or the
    /// target app is no longer frontmost. One member and not two, for the reason
    /// `Keyboard.check` gives. [LAW:one-type-per-behavior]
    func check() throws
    func down(_ button: Button) throws
    func releaseAll() throws
    func move(by delta: Move) throws
    func scroll(by delta: Scroll) throws
}

/// A mouse, refusing any report this run has lost the right to post. The mirror of
/// `GuardedKeyboard`: the device, the operator's interrupt and the app in front meet here
/// and nowhere else. [LAW:decomposition]
public struct GuardedMouse: Mouse {
    public let pointing: any Pointing
    public let interrupt: Interrupt
    public let screen: TargetApp

    public init(pointing: any Pointing, interrupt: Interrupt, screen: TargetApp) {
        self.pointing = pointing
        self.interrupt = interrupt
        self.screen = screen
    }

    public func check() throws {
        try interrupt.check()
        try screen.requireFrontmost()
    }

    public func down(_ button: Button) throws { try pointing.down(button) }
    public func releaseAll() throws { try pointing.releaseAll() }
    public func move(by delta: Move) throws { try pointing.move(by: delta) }
    public func scroll(by delta: Scroll) throws { try pointing.scroll(by: delta) }
}
