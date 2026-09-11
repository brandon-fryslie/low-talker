/// One key of a chord as the keyboard reports it moving: a modifier, told apart by
/// side, or any other key by its code.
public enum ChordKey: Hashable, Sendable {
    case modifier(Modifier)
    case key(Key)
}

/// A key going down or up, with what the keyboard held once it had.
///
/// [LAW:one-source-of-truth] `modifiers` is the whole modifier state as the event
/// reports it, not a running tally kept here: a tally would drift the first time an
/// event was missed (the tap disabled, the app not yet running), and nothing could
/// tell it had.
public struct KeyEvent: Hashable, Sendable {
    public enum Direction: Hashable, Sendable {
        case down, up
    }

    public let key: ChordKey
    public let direction: Direction
    /// Every modifier held after this event.
    public let modifiers: Set<Modifier>
    /// When the key moved.
    public let time: HostTime

    public init(key: ChordKey, direction: Direction, modifiers: Set<Modifier>, time: HostTime) {
        self.key = key
        self.direction = direction
        self.modifiers = modifiers
        self.time = time
    }
}

extension KeyChord {
    /// Whether `key` going down, leaving `held` as the modifiers, is this chord being
    /// pressed. A chord with a key completes on that key, its modifiers already held;
    /// one without completes on whichever of its modifiers comes down last.
    func isCompleted(by key: ChordKey, holding held: Set<Modifier>) -> Bool {
        switch (self.key, key) {
        case (nil, .modifier(let modifier)): held == modifiers && modifiers.contains(modifier)
        case (let expected?, .key(let pressed)): held == modifiers && expected == pressed
        case (nil, .key), (.some, .modifier): false
        }
    }

    func contains(_ key: ChordKey) -> Bool {
        switch key {
        case .modifier(let modifier): modifiers.contains(modifier)
        case .key(let pressed): self.key == pressed
        }
    }
}

/// Finds presses of the configured chords in the keyboard's events, tells a hold
/// from a tap, and says which events the frontmost app must not see.
///
/// A press begins the moment a chord is completed, so listening starts on key-down.
/// Releasing within `tapThreshold` makes it a tap: listening stays on, latched,
/// until the next chord press ends it. Releasing later makes it a hold, which ends
/// as the key comes up. The chord that began a press owns it: keys added during a
/// hold change nothing, and the press ends when any key of its chord comes up.
///
/// [LAW:effects-at-boundaries] A value with no clock and no tap. Time comes in on
/// each event, so a test drives it with timestamps of its choosing.
public struct HotkeyDetector: Sendable {
    public enum Transition: Hashable, Sendable {
        /// The chord went down at this moment; listening begins there rather than
        /// wherever the handler happens to run, which is later by however late the
        /// event was delivered.
        case began(KeyChord, at: HostTime)
        /// Listening ends, and why.
        case ended(KeyChord, Ending)
    }

    /// What stopped the listening: the speaker let go, or the tap went deaf and the
    /// press was ended without them.
    ///
    /// [LAW:types-are-the-program] Two facts a caller could never pull back apart if
    /// they shared a value - "that was the whole utterance" and "that is as much of it
    /// as reached us". Only a release carries a press kind, because a tap and a hold
    /// are told apart by how long the key was down and only a release has the key-up
    /// that measures it. `began` carries the moment its event was stamped with for the
    /// same reason: an ending with no event behind it could only invent one.
    public enum Ending: Hashable, Sendable, CustomStringConvertible {
        /// The key came up on a hold, or the chord went down again on a latched tap.
        case released(PressKind)
        /// Events were missed while the press was open. Nothing was heard past the last
        /// event the tap delivered, and whether the speaker had even finished is unknown
        /// - their release may be among the events that were lost.
        case lapsed

        /// An ending in a person's words. A case added here has to say what it is before
        /// it compiles, so nothing prints an ending it has no word for.
        public var description: String {
            switch self {
            case .released(let kind): kind.rawValue
            case .lapsed: "lapsed"
            }
        }
    }

    /// What the frontmost app gets: the event, or nothing.
    public enum Delivery: Hashable, Sendable {
        case pass, swallow
    }

    public struct Verdict: Hashable, Sendable {
        public let transition: Transition?
        public let delivery: Delivery

        public init(transition: Transition?, delivery: Delivery) {
            self.transition = transition
            self.delivery = delivery
        }
    }

    public enum Phase: Hashable, Sendable {
        case idle
        /// The chord is down and the press is not yet known to be a hold or a tap.
        case held(KeyChord, since: HostTime)
        /// A tap left listening on; the next chord press ends it.
        case latched(KeyChord)
    }

    public let chords: Set<KeyChord>
    /// A press released before this long is a tap.
    public let tapThreshold: Duration
    public private(set) var phase: Phase = .idle
    /// Keys whose down was swallowed and whose up has not come, so it is swallowed
    /// too and the app sees each key move a balanced number of times. Beside the
    /// phase rather than in it: a press can end, and the next begin, while a
    /// swallowed key is still down. An up that went by during a lapse leaves the key
    /// here until its next down, which is swallowed with its up: one press unseen.
    private var swallowing: Set<ChordKey> = []

    public init(chords: Set<KeyChord>, tapThreshold: Duration) {
        precondition(tapThreshold > .zero, "a tap is a press shorter than something; zero makes every press a hold")
        self.chords = chords
        self.tapThreshold = tapThreshold
    }

    public mutating func handle(_ event: KeyEvent) -> Verdict {
        switch event.direction {
        case .down: down(of: event)
        case .up: up(of: event)
        }
    }

    /// A press is only ever begun from rest: while a chord is held, another chord
    /// completed on top of it (Right Option held, Shift added) changes nothing.
    private mutating func down(of event: KeyEvent) -> Verdict {
        // At most one chord completes on one event: two with the same modifiers are
        // told apart by having a key or not, and the event's key settles which.
        let completed = chords.first { $0.isCompleted(by: event.key, holding: event.modifiers) }
        switch (phase, completed) {
        case (.idle, let chord?):
            phase = .held(chord, since: event.time)
            swallowing.insert(event.key)
            return Verdict(transition: .began(chord, at: event.time), delivery: .swallow)
        case (.latched(let chord), .some):
            phase = .idle
            swallowing.insert(event.key)
            return Verdict(transition: .ended(chord, .released(.tap)), delivery: .swallow)
        case (.held, _), (_, nil):
            // A key still swallowed repeats while held; the app sees none of the repeats.
            return Verdict(transition: nil, delivery: swallowing.contains(event.key) ? .swallow : .pass)
        }
    }

    private mutating func up(of event: KeyEvent) -> Verdict {
        let delivery: Delivery = swallowing.remove(event.key) == nil ? .pass : .swallow
        switch phase {
        case .held(let chord, let since) where chord.contains(event.key):
            let press: PressKind = event.time - since < tapThreshold ? .tap : .hold
            switch press {
            case .tap:
                phase = .latched(chord)
                return Verdict(transition: nil, delivery: delivery)
            case .hold:
                phase = .idle
                return Verdict(transition: .ended(chord, .released(.hold)), delivery: delivery)
            }
        case .held, .latched, .idle:
            return Verdict(transition: nil, delivery: delivery)
        }
    }

    /// Events were missed: the open press ends, since its release may have gone by
    /// unseen. What was swallowed stays so; the app never saw those keys go down.
    ///
    /// A hold and a latched tap end the same way here, because what ends them is the
    /// same thing and it is not the speaker. Naming one `.hold` and the other `.tap`
    /// was the invention this ending exists to stop.
    public mutating func lapse() -> Transition? {
        let transition: Transition? = switch phase {
        case .idle: nil
        case .held(let chord, _), .latched(let chord): .ended(chord, .lapsed)
        }
        phase = .idle
        return transition
    }
}
