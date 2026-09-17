import Carbon.HIToolbox
import Dispatch
import Flavors

/// The system switching the keyboard tap off for being slow to answer. The events in
/// between were lost.
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
/// `response` travels with it for a sharper reason: "the tap lost some keys and is
/// listening again" and "the tap is down and this app has no hotkey" are two different
/// facts about the session, and a reader handed only a count cannot tell which one it
/// is holding.
public struct KeyboardTapLapse: Hashable, Sendable, CustomStringConvertible {
    /// Lapses since `Hotkey.start`, this one counted: the first reports 1.
    ///
    /// Every lapse, whatever its cause. This is not the number the cap is drawn against -
    /// that one counts only the recent ones this app was too slow for - so nothing here
    /// offers it as the reason a tap came down.
    public let count: Int
    /// Why the system switched the tap off.
    public let cause: LapseCause
    /// What the tap did about this one.
    public let response: LapseResponse

    public init(count: Int, cause: LapseCause, response: LapseResponse) {
        self.count = count
        self.cause = cause
        self.response = response
    }

    private var why: String {
        switch cause {
        case .tooSlow: "this app did not answer the window server in time"
        case .userInput: "the system switched it off around the user's own input"
        }
    }

    public var description: String {
        switch response {
        case .rearm:
            "the keyboard tap lapsed and was switched back on, losing the events in between - \(why); \(count) since listening began"
        case .comeDown:
            "the keyboard tap has been taken down for lapsing too often - \(why); \(count) lapses since listening began, and the hotkey is off until it is started again"
        }
    }
}

/// The hotkey for the life of the app: a tap in front of the session's keyboard,
/// a detector reading its events, and the presses it finds handed on.
///
/// Inside the tap's callback this does one thing: ask the detector what to do with the
/// event and answer the window server. Everything a press sets in motion leaves by the
/// main queue once that answer is given. An active tap is a gate the whole session's
/// keyboard queues behind, and a callback that opens a microphone or asks another
/// process what is in front holds every key on the Mac for as long as that takes.
/// [LAW:effects-at-boundaries]
@MainActor
public final class Hotkey {
    nonisolated public static let defaultTapThreshold: Duration = .milliseconds(250)
    /// How many lapses inside `lapseWindow` mean the tap is not recovering, and comes
    /// down instead of going back on.
    ///
    /// A tap lapses because this app took too long to answer the window server, and
    /// every lapse is keystrokes the user typed and nobody received. One is a bad
    /// moment - a wake, a model loading - and worth riding out. Several inside a minute
    /// is a process that cannot hold up its end, and each re-arm buys another round of
    /// swallowed keys. At that point the tap is costing the session more than the hotkey
    /// returns, and the only answer that respects the user is to get out of the way.
    ///
    /// [LAW:no-silent-failure] A tap that re-arms without limit is a smoke alarm with
    /// the battery out: it can go on taking the keyboard for as long as the app runs and
    /// report it nowhere the user will look.
    nonisolated public static let lapsesBeforeComingDown = 5
    /// The span `lapsesBeforeComingDown` is counted over. Long enough that lapses from
    /// separate bad moments do not accumulate into a false verdict, short enough that a
    /// tap failing repeatedly is caught while the user is still in front of it.
    ///
    /// A minute of the machine being awake, not a minute of wall clock: lapses are stamped
    /// on `HostTime`, which counts up-time and stands still while the Mac sleeps. That is
    /// the measure this cap wants. Every lapse is a moment this app was running and did not
    /// answer in time, so the question is whether it has failed repeatedly across a short
    /// span of *running* - and hours of sleep between two lapses is not evidence that the
    /// second one is a fresh incident. Reading a wall clock here would also put a second
    /// time base in a decision `HostTime` already answers, and hand it one that can jump
    /// under it. [LAW:one-source-of-truth]
    nonisolated public static let lapseWindow: Duration = .seconds(60)
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
    /// The moments of the recent lapses this app was too slow for, which is the whole of
    /// what deciding to come down needs to know. Trimmed on each one, so it holds at most
    /// `lapsesBeforeComingDown` of them and never grows with the app's life.
    ///
    /// Only `.tooSlow` lands here. A lapse the system took around the user's own input is
    /// not something this app can go faster to avoid, so counting it would take the hotkey
    /// down for something it did not do.
    private var recentLapses: [HostTime] = []

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

    /// Whether a tap is up and presses are being heard.
    ///
    /// False before the first `start`, after `stop`, and after a tap that kept lapsing
    /// was taken down. [LAW:one-source-of-truth] derived from the installation itself, so
    /// it cannot disagree with whether anything is actually listening - which is the
    /// question a caller offering the user a way to start it again has to ask.
    public var isWatching: Bool { installed != nil }

    /// Starts watching. Each press begins and ends at `onTransition`, and every lapse
    /// of the tap arrives at `onLapse`, both on the main actor and both on the main
    /// queue once the tap's callback has answered - never inside it. Neither is bound by
    /// the window server's deadline, so either may take as long as its work takes. The
    /// count begins again here: it counts the tap that is up now, not the app's whole
    /// life.
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
        recentLapses = []
        let dispose = try tap.install(
            listeningFor: detector.chords,
            handling: { [weak self] event in self?.handle(event, onTransition) ?? .pass },
            // A hotkey that has been released cannot decide anything, and an armed tap
            // with nothing behind it is a gate in front of the session's keyboard that
            // nobody is minding.
            onLapse: { [weak self] moment, cause in
                self?.lapse(at: moment, because: cause, onTransition, onLapse) ?? .comeDown
            }
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
        unfinished.map { transition in
            was.map { installation in after { installation.onTransition(transition) } }
        }
    }

    // A non-Sendable @MainActor class is only ever held by main-actor code, so its
    // last release is on the main actor; assumeIsolated traps if that stops holding.
    // Only the tap comes down: nothing is left to hear an ending told from here.
    deinit { MainActor.assumeIsolated { installed?.dispose() } }

    /// Runs `work` on the main queue once the tap's callback has returned.
    ///
    /// [LAW:single-enforcer] The one way anything leaves this class. The main queue is
    /// first-in-first-out, which is what keeps a `began` ahead of the `ended` that
    /// follows it: `Dictation.press` traps on a pair out of order rather than repairing
    /// one, so the order is a correctness property and not a preference.
    private func after(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }

    private func handle(_ event: KeyEvent, _ onTransition: @escaping @MainActor (HotkeyDetector.Transition) -> Void) -> HotkeyDetector.Delivery {
        let verdict = detector.handle(event)
        verdict.transition.map { transition in after { onTransition(transition) } }
        return verdict.delivery
    }

    /// Counts this lapse, says whether the tap goes back on, and reports it.
    ///
    /// The answer is worked out here and now because the tap is waiting on it; the
    /// report goes out afterwards like everything else.
    private func lapse(
        at moment: HostTime,
        because cause: LapseCause,
        _ onTransition: @escaping @MainActor (HotkeyDetector.Transition) -> Void,
        _ onLapse: @escaping @MainActor (KeyboardTapLapse) -> Void
    ) -> LapseResponse {
        lapses += 1
        switch cause {
        case .tooSlow:
            recentLapses.removeAll { moment - $0 >= Self.lapseWindow }
            recentLapses.append(moment)
        case .userInput:
            break
        }
        let response: LapseResponse = recentLapses.count >= Self.lapsesBeforeComingDown ? .comeDown : .rearm
        let lapse = KeyboardTapLapse(count: lapses, cause: cause, response: response)
        // Ended here rather than inside the teardown below, so the press is ended once
        // however the two are ordered.
        let unfinished = detector.lapse()
        // **Down before it is reported.** A tap left switched off is still an installation
        // holding a disposal, and `isWatching` would go on saying this hotkey is up. It is
        // taken down once the callback has returned, which is the only point it is safe to
        // dispose the port the callback is running inside - and it goes on the queue ahead
        // of the report so that a handler told the tap has come down finds it already
        // down. A hotkey started from that handler, which is exactly what the report
        // invites, would otherwise be disposed by this teardown a turn later.
        switch response {
        case .rearm: break
        case .comeDown: after { [weak self] in self?.stop() }
        }
        // The lapse before what it did to the press, so a reader of either meets the
        // cause ahead of the consequence.
        after { onLapse(lapse) }
        unfinished.map { transition in after { onTransition(transition) } }
        return response
    }
}
