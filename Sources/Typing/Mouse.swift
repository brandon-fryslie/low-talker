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
    /// Throws rather than let the next report be posted: the operator interrupted, the
    /// target app is no longer frontmost, or macOS has put an alert over everything. One
    /// member and not two, for the reason `Keyboard.check` gives.
    /// [LAW:one-type-per-behavior]
    func check() throws
    func down(_ button: Button) throws
    func releaseAll() throws
    func move(by delta: Move) throws
    func scroll(by delta: Scroll) throws
}

/// A mouse, refusing any report this run has lost the right to post. The mirror of
/// `GuardedKeyboard`: the device, the operator's interrupt, the app in front and the
/// alerts over it meet here and nowhere else. [LAW:decomposition]
public struct GuardedMouse: Mouse {
    public let pointing: any Pointing
    public let interrupt: Interrupt
    public let screen: TargetApp

    public init(pointing: any Pointing, interrupt: Interrupt, screen: TargetApp) {
        self.pointing = pointing
        self.interrupt = interrupt
        self.screen = screen
    }

    /// [LAW:single-enforcer] The alert refusal lives here rather than in whichever command
    /// happened to start the click. `Pointer` calls this before every motion report and
    /// again immediately before the button goes down, so an alert that opens while the
    /// cursor is still travelling - the several seconds an element search and a move can
    /// take - is caught at the last report instead of only at the first. And every caller
    /// of the mechanism inherits it: `act`'s routed `clickElement` reaches the same
    /// `Pointer.click`, and a guard sitting in one CLI command would have left that door
    /// open.
    public func check() throws {
        try interrupt.check()
        try screen.requireFrontmost()
        try SystemAlerts.requireNone()
    }

    public func down(_ button: Button) throws { try pointing.down(button) }
    public func releaseAll() throws { try pointing.releaseAll() }
    public func move(by delta: Move) throws { try pointing.move(by: delta) }
    public func scroll(by delta: Scroll) throws { try pointing.scroll(by: delta) }
}
