import Flavors
/// The system switching the keyboard tap off for being slow to answer, and it being
/// switched back on. The events in between were lost.
///
/// Reported whether or not a press was open to end, because only one of the two leaves
/// anything else behind. A lapse during a press also ends it as `.lapsed`, and the press
/// is reported in its own right; a lapse with no press open is reported here and nowhere
/// else, and that is the one that swallows the next key-down and takes the beginning of
/// the next utterance with it.
///
/// [LAW:types-are-the-program] The count travels with the lapse rather than being left
/// on the tap for a reader to ask for afterwards: a count read later is the count as of
/// the asking, which by the second lapse is not the number that belongs to this one.
public struct KeyboardTapLapse: Hashable, Sendable, CustomStringConvertible {
    /// Lapses since `Hotkey.start`, this one counted: the first reports 1.
    public let count: Int

    public init(count: Int) {
        self.count = count
    }

    public var description: String {
        "the keyboard tap lapsed and was switched back on, losing the events in between; \(count) since listening began"
    }
}

/// The hotkey for the life of the app: a tap in front of the session's keyboard,
/// a detector reading its events, and the presses it finds handed on as they happen.
///
/// The handler runs inside the tap's callback, on the main actor, so key-down reaches
/// the pipeline with nothing in between; what it does there must be quick, since a
/// slow handler is what makes the system switch the tap off.
@MainActor
public final class Hotkey {
    nonisolated public static let defaultTapThreshold: Duration = .milliseconds(250)
    /// The chord an installation listens for until its config file says otherwise.
    ///
    /// Right Option for the installed copy, and Right Option held together with Right
    /// Command for the development one. The development chord is a superset of the
    /// release chord rather than a different key, which works because a chord is matched
    /// by exact equality of what is held: `{rightOption, rightCommand}` is not
    /// `{rightOption}`, so holding both is the development hotkey and neither
    /// installation has to know the other's. [LAW:dataflow-not-control-flow]
    ///
    /// **Right Command goes down first.** A chord completes on whichever of its
    /// modifiers comes down last, and the press it begins owns the hold until one of its
    /// keys comes up. Pressing Right Option first therefore completes the release chord
    /// exactly, starting a press there before Right Command can make it the development
    /// one, and both installations then listen. Right Command alone completes nothing, so
    /// starting with it leaves only the development chord to complete.
    ///
    /// Named once per installation: the tap listens for it and the typist refuses to
    /// press it, and two spellings of one chord would be a hotkey the typist could type.
    /// [LAW:one-source-of-truth]
    nonisolated public static func defaultChord(for flavor: Flavor) -> KeyChord {
        switch flavor {
        case .release: KeyChord(modifiers: .rightOption)
        case .development: KeyChord(modifiers: .rightOption, .rightCommand)
        }
    }

    private let tap: any KeyboardTap
    private var detector: HotkeyDetector
    private var installed: Disposal?
    /// Lapses since `start()`, which each one is reported with. Private because a
    /// second way to ask is a second answer: this one moves between the lapse and any
    /// later reading of it. [LAW:one-source-of-truth]
    private var lapses = 0

    public init(chords: Set<KeyChord>, tapThreshold: Duration = defaultTapThreshold, tap: any KeyboardTap = SystemKeyboardTap()) {
        self.tap = tap
        detector = HotkeyDetector(chords: chords, tapThreshold: tapThreshold)
    }

    public var phase: HotkeyDetector.Phase { detector.phase }

    /// Starts watching. Each press begins and ends at `onTransition`, and every lapse
    /// of the tap arrives at `onLapse`, both on the main actor, from inside the tap's
    /// callback. The count begins again here: it counts the tap that is up now, not the
    /// app's whole life.
    ///
    /// [LAW:no-silent-failure] `onLapse` has no default. A caller that watches the
    /// keyboard is a caller that can find out the keyboard went unwatched, and a
    /// default would let that be nothing, silently, at a call site that reads as
    /// complete.
    public func start(
        _ onTransition: @escaping @MainActor (HotkeyDetector.Transition) -> Void,
        onLapse: @escaping @MainActor (KeyboardTapLapse) -> Void
    ) throws {
        stop()
        lapses = 0
        installed = try tap.install(
            handling: { [weak self] event in self?.handle(event, onTransition) ?? .pass },
            onLapse: { [weak self] in self?.lapse(onTransition, onLapse) }
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

    private func lapse(
        _ onTransition: @MainActor (HotkeyDetector.Transition) -> Void,
        _ onLapse: @MainActor (KeyboardTapLapse) -> Void
    ) {
        lapses += 1
        // The lapse before what it did to the press, so a reader of either meets the
        // cause ahead of the consequence.
        onLapse(KeyboardTapLapse(count: lapses))
        detector.lapse().map(onTransition)
    }
}
