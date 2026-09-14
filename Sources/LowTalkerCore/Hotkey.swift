import Carbon.HIToolbox
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
    ///
    /// **A registered hot key cannot be a modifier alone**, so the clipboard method, which
    /// hears its hotkey that way, gets a key: Control+Shift+D, and Command added for the
    /// development copy. Carbon matches modifiers exactly, so neither completes the other.
    /// Not Control+Option, which is VoiceOver's modifier: VoiceOver takes Control+Option+D
    /// as a move to the Dock.
    nonisolated public static func defaultChord(for flavor: Flavor, heardBy method: InputMethod) -> KeyChord {
        let d = Key(rawValue: UInt16(kVK_ANSI_D))
        return switch (method, flavor) {
        case (.virtualKeyboard, .release): KeyChord(modifiers: .rightOption)
        case (.virtualKeyboard, .development): KeyChord(modifiers: .rightOption, .rightCommand)
        case (.clipboard, .release): KeyChord(key: d, modifiers: [.leftControl, .leftShift])
        case (.clipboard, .development): KeyChord(key: d, modifiers: [.leftControl, .leftShift, .leftCommand])
        }
    }

    /// Every installation's chord, which is the set a typist must refuse to press.
    ///
    /// [LAW:one-source-of-truth] A typist that refused only its own installation's chord
    /// still refused *a* hotkey, which is what made the omission read as complete at each
    /// call site that spelled it. But the release chord is a strict subset of
    /// the development one, and the helper's keystrokes are hardware to macOS: a
    /// development typist pressing a bare Right Option is the release app's hotkey
    /// exactly, so the transcript starts a dictation in the other copy. The fact is "every
    /// chord an installation listens for", it is one fact, and it is derived here from
    /// `Flavor.allCases` so a third flavor is covered by existing. [LAW:dataflow-not-control-flow]
    ///
    /// Every flavor's, not every *installed* flavor's: whether the other copy is on this
    /// Mac is a question with a different answer every minute, and a typist that refused
    /// on the strength of it would type the chord in the window where the answer was
    /// stale. The cost of refusing a chord nobody listens for is a keystroke the helper
    /// declines; the cost of the other mistake is two apps dictating at once.
    ///
    /// Every method's too, for the same reason: which method the other copy is on is a
    /// choice its user can change from its menu at any moment.
    nonisolated public static let everyInstallationsChord: Set<KeyChord> =
        Set(Flavor.allCases.flatMap { flavor in InputMethod.allCases.map { defaultChord(for: flavor, heardBy: $0) } })

    /// This chord's modifiers in the order a person must press them.
    ///
    /// [LAW:one-source-of-truth] The order was a fact recorded only in prose - "Right
    /// Command goes down first" in the comment above - while the string a person actually
    /// reads was ordered by `Modifier.allCases`, and so printed
    /// `rightOption+rightCommand`: the one order that does not work. Two maps of
    /// one territory, and the one the user was handed was the wrong one.
    ///
    /// A chord completes on whichever modifier comes down last, so pressing them in an
    /// order whose prefix is another installation's whole chord starts a press *there*
    /// first. The order is therefore not arbitrary and not remembered: a modifier no other
    /// chord contains can never complete one, so those go down first, and the shared ones
    /// go down last. `theOrderPrintedIsAnOrderThatWorks` holds that to every flavor.
    /// [LAW:verifiable-goals]
    nonisolated public static func pressOrder(of chord: KeyChord) -> [Modifier] {
        // Only a chord of modifiers alone completes while modifiers go down; one with a key
        // waits for its key, so no order of holding modifiers can start it.
        let rivals = everyInstallationsChord.subtracting([chord]).filter { $0.key == nil }.map(\.modifiers)
        // How many other installations' chords this modifier appears in. Zero means it
        // cannot complete one of theirs, so it is safe to hold early.
        func shared(_ modifier: Modifier) -> Int { rivals.filter { $0.contains(modifier) }.count }
        // `Modifier.allCases` breaks ties, so one chord always spells one order: `sorted`
        // is not stable, and an order that varied between two readings of the same chord
        // would be two instructions for one hotkey. [LAW:one-source-of-truth]
        return Modifier.allCases
            .filter(chord.modifiers.contains)
            .enumerated()
            .sorted { (shared($0.element), $0.offset) < (shared($1.element), $1.offset) }
            .map(\.element)
    }

    /// The chord in words: what to hold, in the order to hold it, then the key to strike.
    ///
    /// [LAW:one-source-of-truth] The one spelling of a chord for every place one is named,
    /// an instruction or a refusal. An instruction needs the order that works; a refusal
    /// needs only a stable one, and the order that works is stable. Two spellings are how
    /// the menu came to print the order that starts the other installation dictating.
    nonisolated public static func held(_ chord: KeyChord) -> String {
        let struck = chord.key.map { ["key 0x" + String($0.rawValue, radix: 16)] } ?? []
        return (pressOrder(of: chord).map(\.rawValue) + struck).joined(separator: "+")
    }

    private let tap: any KeyboardTap
    private var detector: HotkeyDetector
    /// The tap that is up, and the handler its presses go to - kept together because a
    /// press still open when the tap comes down is ended at that same handler.
    private var installed: (dispose: Disposal, onTransition: @MainActor (HotkeyDetector.Transition) -> Void)?
    /// Lapses since `start()`, which each one is reported with. Private because a
    /// second way to ask is a second answer: this one moves between the lapse and any
    /// later reading of it. [LAW:one-source-of-truth]
    private var lapses = 0

    public init(chords: Set<KeyChord>, tapThreshold: Duration = defaultTapThreshold, tap: any KeyboardTap = SystemKeyboardTap()) {
        self.tap = tap
        detector = HotkeyDetector(chords: chords, tapThreshold: tapThreshold)
    }

    /// An installation's hotkey as its input method hears it: that method's chord, through
    /// that method's tap. [LAW:one-source-of-truth] The one place a method becomes the pair,
    /// so a chord can never be handed to a tap that cannot hear it.
    public convenience init(for flavor: Flavor, heardBy method: InputMethod, tapThreshold: Duration = defaultTapThreshold) {
        let tap: any KeyboardTap = switch method {
        case .virtualKeyboard: SystemKeyboardTap()
        case .clipboard: RegisteredHotKeys()
        }
        self.init(chords: [Self.defaultChord(for: flavor, heardBy: method)], tapThreshold: tapThreshold, tap: tap)
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
        let dispose = try tap.install(
            listeningFor: detector.chords,
            handling: { [weak self] event in self?.handle(event, onTransition) ?? .pass },
            onLapse: { [weak self] in self?.lapse(onTransition, onLapse) }
        )
        installed = (dispose, onTransition)
    }

    /// Stops watching. A press still open is ended here as `.lapsed`, at the handler it
    /// began at: once the tap is down its release can never arrive, and a press left open
    /// is a microphone left open with nothing to close it.
    /// [LAW:no-ambient-temporal-coupling]
    public func stop() {
        let unfinished = detector.lapse()
        let was = installed
        installed = nil
        was?.dispose()
        detector = HotkeyDetector(chords: detector.chords, tapThreshold: detector.tapThreshold)
        unfinished.map { was?.onTransition($0) }
    }

    // A non-Sendable @MainActor class is only ever held by main-actor code, so its
    // last release is on the main actor; assumeIsolated traps if that stops holding.
    // Only the tap comes down: nothing is left to hear an ending told from here.
    deinit { MainActor.assumeIsolated { installed?.dispose() } }

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
