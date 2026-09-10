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
/// only the main actor may ask. The reports are awaited, for the reason `Keyboard`'s keys
/// are.
@MainActor
public protocol Mouse {
    /// Throws rather than let the next report be posted: the operator interrupted, or the
    /// target app is no longer frontmost. One member and not two, for the reason
    /// `Keyboard.check` gives. [LAW:one-type-per-behavior]
    func check() throws
    func down(_ button: Button) async throws
    func releaseAll() async throws
    func move(by delta: Move) async throws
    func scroll(by delta: Scroll) async throws
}

/// A mouse, refusing any report this run has lost the right to post. The mirror of
/// `GuardedKeyboard`: the device, the operator's interrupt, the app in front and the
/// alerts over it meet here and nowhere else. [LAW:decomposition]
public struct GuardedMouse: Mouse {
    public let pointing: any Pointing
    public let interrupt: Interrupt
    public let screen: TargetApp
    /// The alert reading taken as a parameter rather than read inside `down`, for the
    /// reason `Screenshot.capture` takes the Screen Recording grant: it lets a test ask
    /// what a press does with an alert on a screen it does not have.
    /// [LAW:effects-at-boundaries]
    public let alerts: @MainActor () throws -> Void

    public init(
        pointing: any Pointing,
        interrupt: Interrupt,
        screen: TargetApp,
        alerts: @escaping @MainActor () throws -> Void = SystemAlerts.requireNone
    ) {
        self.pointing = pointing
        self.interrupt = interrupt
        self.screen = screen
        self.alerts = alerts
    }

    /// [LAW:single-enforcer] The interrupt and the frontmost app are proven here rather
    /// than in whichever command started the click, so every caller inherits them.
    public func check() throws {
        try interrupt.check()
        try screen.requireFrontmost()
    }

    /// [LAW:single-enforcer] The alert refusal sits at the press and not in `check`: a
    /// motion or wheel report cannot answer somebody else's prompt, and a button going
    /// down can. `Pointer.click` calls `check` and then this, so it is still asked at the
    /// last instant before the press, without a move paying for it once per motion report.
    public func down(_ button: Button) async throws {
        try alerts()
        try await DeviceQueue.run { [pointing] in try pointing.down(button) }
    }

    public func releaseAll() async throws { try await DeviceQueue.run { [pointing] in try pointing.releaseAll() } }
    public func move(by delta: Move) async throws { try await DeviceQueue.run { [pointing] in try pointing.move(by: delta) } }
    public func scroll(by delta: Scroll) async throws { try await DeviceQueue.run { [pointing] in try pointing.scroll(by: delta) } }
}
