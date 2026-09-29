import Dispatch
import Flavors

/// The hotkey for the life of the app: the modifier keys as the input method tells them, a
/// detector reading them, and the presses it finds handed on by the main queue.
@MainActor
public final class Hotkey {
    nonisolated public static let defaultTapThreshold: Duration = .milliseconds(250)
    /// The chord an installation listens for where its config names no other.
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
    nonisolated public static func defaultChord(for flavor: Flavor) -> KeyChord {
        switch flavor {
        case .release: KeyChord(modifiers: .rightOption)
        case .development: KeyChord(modifiers: .rightOption, .rightCommand)
        }
    }

    /// Every installation's chord, as it stands with no config: the chords `pressOrder`
    /// orders a press around. The defaults, because they are all an installation can know -
    /// App Sandbox keeps each one's config file in its own container, where no other copy
    /// may read it.
    nonisolated public static let everyInstallationsChord = Set(Flavor.allCases.map(defaultChord(for:)))

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
        let rivals = everyInstallationsChord.subtracting([chord]).map(\.modifiers)
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

    /// The chord in the words a person presses it by, in the order `pressOrder` says to hold
    /// them: `rightOption` as "Right Option", the case's own name split at its capitals, so no
    /// table of names stands beside the cases to fall out of step with them.
    nonisolated public static func named(_ chord: KeyChord) -> String {
        pressOrder(of: chord).map { modifier in
            modifier.rawValue.reduce(into: "") { name, letter in
                name += name.isEmpty ? letter.uppercased() : letter.isUppercase ? " \(letter)" : String(letter)
            }
        }.joined(separator: "+")
    }

    /// Every chord `config` listens for, named as above, in the order the file declares its
    /// modes.
    nonisolated public static func named(in config: Config) -> String {
        config.modes.map { named($0.chord) }.joined(separator: " or ")
    }

    private let feed: any ModifierFeed
    private var detector: HotkeyDetector
    /// The feed that is running, and the handler its presses go to - kept together because a
    /// press still open when the feed stops is ended at that same handler.
    private var installed: (dispose: Disposal, onTransition: @MainActor (HotkeyDetector.Transition) -> Void)?

    public init(chords: Set<KeyChord>, tapThreshold: Duration = defaultTapThreshold, feed: any ModifierFeed) {
        self.feed = feed
        detector = HotkeyDetector(chords: chords, tapThreshold: tapThreshold)
    }

    /// An installation's hotkey: the chords `config` names, heard through its input method.
    public convenience init(for flavor: Flavor, listeningFor config: Config, tapThreshold: Duration = defaultTapThreshold) {
        self.init(chords: config.chords, tapThreshold: tapThreshold, feed: InputMethodModifiers(flavor: flavor))
    }

    public var phase: HotkeyDetector.Phase { detector.phase }

    /// Whether the feed is running and presses are being heard.
    ///
    /// False before the first `start`, and after `stop`. [LAW:one-source-of-truth] derived
    /// from the installation itself, so it cannot disagree with whether anything is actually
    /// listening - which is the question a caller offering the user a way to start it again
    /// has to ask.
    public var isWatching: Bool { installed != nil }

    /// Starts watching. Each press begins and ends at `onTransition`, on the main actor and
    /// on the main queue.
    public func start(_ onTransition: @escaping @MainActor (HotkeyDetector.Transition) -> Void) throws {
        stop()
        let dispose = try feed.install { [weak self] event in self?.handle(event, onTransition) }
        installed = (dispose, onTransition)
    }

    /// Stops watching. A press still open is ended here as `.lapsed`, at the handler it
    /// began at: once the feed has stopped its release can never arrive, and a press left open
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

    /// Stops watching, and returns once everything already handed to the main queue has
    /// been delivered.
    ///
    /// [LAW:single-enforcer] What a caller waiting out a loop's sessions needs is both of
    /// these, in this order, and the pairing lives here rather than at each call site.
    /// Presses leave by the main queue, so a key-up told moments ago can still be
    /// sitting on it, and a wait on the sessions a loop has been given cannot cover one
    /// that has not reached it yet. Spelled out at three teardowns and forgotten at a
    /// fourth, that is a final session lost in silence - which is the failure the wait was
    /// put there to prevent.
    ///
    /// [LAW:no-ambient-temporal-coupling] The queue itself is waited on, never a duration
    /// chosen to be long enough, so this is exactly as long as the work and no longer.
    public func stopAndDeliver() async {
        stop()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    // A non-Sendable @MainActor class is only ever held by main-actor code, so its
    // last release is on the main actor; assumeIsolated traps if that stops holding.
    // Only the feed stops: nothing is left to hear an ending told from here.
    deinit { MainActor.assumeIsolated { installed?.dispose() } }

    /// Runs `work` on the main queue, after the event that caused it has been read.
    ///
    /// [LAW:single-enforcer] The one way anything leaves this class. The main queue is
    /// first-in-first-out, which is what keeps a `began` ahead of the `ended` that
    /// follows it: `Dictation.press` traps on a pair out of order rather than repairing
    /// one, so the order is a correctness property and not a preference.
    private func after(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }

    private func handle(_ event: KeyEvent, _ onTransition: @escaping @MainActor (HotkeyDetector.Transition) -> Void) {
        detector.handle(event).map { transition in after { onTransition(transition) } }
    }
}
