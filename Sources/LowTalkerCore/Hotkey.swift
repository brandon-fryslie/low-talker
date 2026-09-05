/// The hotkey for the life of the app: a tap in front of the session's keyboard,
/// a detector reading its events, and the presses it finds handed on as they happen.
///
/// The handler runs inside the tap's callback, on the main actor, so key-down reaches
/// the pipeline with nothing in between; what it does there must be quick, since a
/// slow handler is what makes the system switch the tap off.
@MainActor
public final class Hotkey {
    public static let defaultTapThreshold: Duration = .milliseconds(250)

    private let tap: any KeyboardTap
    private var detector: HotkeyDetector
    private var installed: Disposal?
    /// Times since `start()` that the system switched the tap off and it was switched
    /// back on. Events in between were lost, so a lapse can leave a press unended.
    public private(set) var lapses = 0

    public init(chords: Set<KeyChord>, tapThreshold: Duration = defaultTapThreshold, tap: any KeyboardTap = SystemKeyboardTap()) {
        self.tap = tap
        detector = HotkeyDetector(chords: chords, tapThreshold: tapThreshold)
    }

    public var phase: HotkeyDetector.Phase { detector.phase }

    /// Starts watching. Each press begins and ends at `onTransition`, on the main
    /// actor, from inside the tap's callback.
    public func start(_ onTransition: @escaping @MainActor (HotkeyDetector.Transition) -> Void) throws {
        stop()
        lapses = 0
        installed = try tap.install(
            handling: { [weak self] event in self?.handle(event, onTransition) ?? .pass },
            onLapse: { [weak self] in self?.lapses += 1 }
        )
    }

    public func stop() {
        installed?()
        installed = nil
        detector = HotkeyDetector(chords: detector.chords, tapThreshold: detector.tapThreshold)
    }

    // A non-Sendable @MainActor class is only ever held by main-actor code, so its
    // last release is on the main actor; assumeIsolated traps if that stops holding.
    deinit { MainActor.assumeIsolated { stop() } }

    private func handle(_ event: KeyEvent, _ onTransition: @MainActor (HotkeyDetector.Transition) -> Void) -> HotkeyDetector.Delivery {
        let verdict = detector.handle(event)
        verdict.transition.map(onTransition)
        return verdict.delivery
    }
}
