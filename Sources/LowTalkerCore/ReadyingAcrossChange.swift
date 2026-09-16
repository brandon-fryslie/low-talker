import CoreAudio

/// Whether a device change leaves the main actor free, and whether a press that lands on one
/// still comes back whole.
///
/// A readied microphone is readied again whenever its device changes shape, goes away, or
/// stops being the default, and those reports land on the main actor - the one the key-down
/// handler runs on. Readying there held that handler for as long as a readying takes, and a
/// run of reports held it for each one, so a key pressed as a dock came up waited for all of
/// them and came back refused. Readying now happens off the main actor; this is what says so
/// on a real device, since a fake's readying costs nothing and a suite would read it as free
/// whichever actor paid.
///
/// Two readings on one device, changed twice. Across the first change, how long the main
/// actor went without a turn, set against what one readying costs on this Mac right then:
/// readying off the main actor leaves bookkeeping on it, and a hold of half a readying or
/// more is a readying being done there. On the second change, a press made the moment the
/// report lands - stamped then, the way a key-down is, and begun once capture has asked for
/// the readying that change needs - held for a moment and ended, and whether its clip came
/// back whole. [LAW:verifiable-goals]
public struct ReadyingAcrossChange: Sendable, CustomStringConvertible {
    /// What became of the press made as the second change landed.
    public enum Press: Sendable, Equatable, CustomStringConvertible {
        /// The clip was whole, and the session had begun this long after the report landed -
        /// capture's own handling of it, the rest of the readying it asked for, and the
        /// opening.
        case whole(beginning: Duration)
        /// The clip lost audio through the doors named.
        case partial(beginning: Duration, lost: String)
        /// The press was refused at the key.
        case refused(String)
        /// The second change never landed, so no press was begun.
        case never

        public var description: String {
            switch self {
            case .whole(let beginning): "a press made as it landed had begun \(Self.milliseconds(beginning)) later and came back whole"
            case .partial(let beginning, let lost): "a press made as it landed had begun \(Self.milliseconds(beginning)) later and came back \(lost)"
            case .refused(let reason): "a press made as it landed was refused: \(reason)"
            case .never: "it never landed, so no press was begun"
            }
        }

        static func milliseconds(_ duration: Duration) -> String {
            "\(Int((duration / .milliseconds(1)).rounded())) ms"
        }
    }

    /// A way this reading can come back wrong, and what holding it means.
    /// [LAW:one-source-of-truth] Each meaning is written once, and the report's lines are
    /// printed from it.
    public enum Fault: Sendable, Equatable, CustomStringConvertible {
        /// The first change never reached the main actor, so the hold was measured across
        /// nothing.
        case unheard
        /// The main actor went half a readying or more without a turn across the change.
        case heldTheMainActor
        /// The press made as the second change landed did not come back whole.
        case pressNotWhole
        /// This reading moved the device and could not move it back.
        case leftReshaped

        public var description: String {
            switch self {
            case .unheard:
                """
                the device changed shape and no report of it reached the main actor, so no readying was asked for and \
                the hold above measures nothing. `lowtalker mic shape` is the reading for a watch that does not hear; \
                raise --wait before believing it on a Mac that may be slow to publish the change
                """
            case .heldTheMainActor:
                """
                the main actor went half a readying or more without a turn across a device change, so a readying is \
                being done on it: a key pressed then waits for all of that before its handler runs, and a run of \
                changes makes it wait for each
                """
            case .pressNotWhole:
                """
                a press made as a device change landed did not come back whole, so what it waited for - the rest of \
                the readying and the opening - came to more than the warm-up a press is allowed. A readying under load \
                can cost that on its own, so set the time the press took to begin against the readying above before \
                reading it as the code
                """
            case .leftReshaped:
                ShapeChangeAtRest.Fault.leftReshaped.description
            }
        }
    }

    public let device: AudioObjectID
    /// What one readying cost on this Mac just before the device was changed.
    public let readying: Duration
    public let readiedAt: Double
    public let movedTo: Double
    /// Whether the first change reached the main actor.
    public let heard: Bool
    /// The longest the main actor went without a turn across the first change.
    public let longestHold: Duration
    public let press: Press
    /// The rate the device was left at, read back off it.
    public let leftAt: Double

    public init(device: AudioObjectID, readying: Duration, readiedAt: Double, movedTo: Double, heard: Bool, longestHold: Duration, press: Press, leftAt: Double) {
        self.device = device
        self.readying = readying
        self.readiedAt = readiedAt
        self.movedTo = movedTo
        self.heard = heard
        self.longestHold = longestHold
        self.press = press
        self.leftAt = leftAt
    }

    /// Every way this reading came back wrong. Empty is both promises kept and the Mac put
    /// back. [LAW:dataflow-not-control-flow] Each is asked and none skips another.
    public var faults: [Fault] {
        let pressWasWhole = if case .whole = press { true } else { false }
        return [
            (Fault.unheard, !heard),
            (Fault.heldTheMainActor, longestHold * 2 >= readying),
            (Fault.pressNotWhole, !pressWasWhole),
            (Fault.leftReshaped, leftAt != readiedAt),
        ]
        .filter(\.1)
        .map(\.0)
    }

    public var kept: Bool { faults.isEmpty }

    public var description: String {
        let heardOrNot = heard ? "heard" : "not heard"
        let reading = """
            device \(device): a readying costs \(Press.milliseconds(readying)); moved from \(readiedAt) Hz to \(movedTo) Hz, \
            \(heardOrNot), the main actor's longest hold \(Press.milliseconds(longestHold)); moved back, \(press); \
            left at \(leftAt) Hz
            """
        return ([reading] + faults.map { "\($0)" }).joined(separator: "\n")
    }

    /// Takes both readings on this Mac's default input, through the capture the app runs and
    /// the resting mode the promise is about.
    ///
    /// Refuses a device already running, for the reason `IndicatorAcrossHold` does, and one
    /// that offers a single shape, for the reason `ShapeChangeAtRest` does. [LAW:no-silent-failure]
    @MainActor
    public static func measure(waiting wait: Duration, holding hold: Duration, with grant: MicrophoneGrant) async throws -> ReadyingAcrossChange {
        guard try MicrophoneIndicator.read() == .dark else { throw MicrophoneAlreadyRunning() }
        let capture = AudioCapture()
        try capture.start(grant, atRest: .shut)
        defer { capture.stop() }
        capture.waitUntilReadied()

        // Taken after capture's own readying, so both this and the one the change causes are
        // warm: the first in a process costs several times what later ones do.
        let clock = ContinuousClock()
        let before = clock.now
        let device = try HALInput(onStale: {}).device
        let readying = clock.now - before

        let readiedAt = try ShapeChangeAtRest.nominalRate(of: device)
        let movedTo = try ShapeChangeAtRest.otherRate(of: device, than: readiedAt)

        // CoreAudio calls a device's listeners in the order they were registered. This one is
        // registered before the input the first change will have capture ready, so for the
        // second change it hears the report ahead of capture - which is where a key pressed as
        // the report landed is stamped: when the key went down, not when its handler got a turn.
        let landing = Arrivals()
        let unwatchLanding = try HALInput.watch(device, kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput) { landing.arrived() }
        defer { unwatchLanding() }

        try ShapeChangeAtRest.move(device, to: movedTo)
        // [LAW:no-ambient-temporal-coupling] Every way out puts the device back, as
        // `ShapeChangeAtRest.report` does. The second change below asks the same, so a run
        // that got that far leaves this with nothing to move.
        defer { try? ShapeChangeAtRest.move(device, to: readiedAt) }
        let longestHold = await longestHold(over: wait, on: clock)
        let heard = landing.last != nil

        // And this one hears it after capture, so the press begins once capture has asked for
        // its readying - that collision is the question. The input capture readied for the
        // first change registers its watch when that readying runs, so this is registered only
        // once it is done.
        capture.waitUntilReadied()
        var began: (session: Result<AudioSession, any Error>, beginning: Duration)?
        let pressing = Arrivals()
        pressing.next = {
            guard let landed = landing.last else { preconditionFailure("a device reported a change to a listener registered after one it skipped") }
            began = (Result { try capture.beginSession(at: landed.moment) }, clock.now - landed.instant)
        }
        let unwatchPressing = try HALInput.watch(device, kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput) { pressing.arrived() }
        defer { unwatchPressing() }
        try ShapeChangeAtRest.move(device, to: readiedAt)
        // CoreAudio publishes the change asynchronously; the press is made inside this wait,
        // whenever the report lands, and a report that never does leaves no press.
        try await Task.sleep(for: wait)
        let press: Press
        switch began {
        case nil:
            press = .never
        case (.failure(let error), _)?:
            press = .refused("\(error)")
        case (.success(let session), let beginning)?:
            try await Task.sleep(for: hold)
            switch capture.endSession(session) {
            case .whole: press = .whole(beginning: beginning)
            case .partial(_, let lost): press = .partial(beginning: beginning, lost: "\(lost)")
            }
        }

        return ReadyingAcrossChange(
            device: device,
            readying: readying,
            readiedAt: readiedAt,
            movedTo: movedTo,
            heard: heard,
            longestHold: longestHold,
            press: press,
            leftAt: try ShapeChangeAtRest.nominalRate(of: device)
        )
    }

    /// The longest stretch over `window` in which the main actor gave this no turn. Each
    /// yield goes to the back of the main queue, behind anything CoreAudio posted there, so a
    /// report handled in the meantime shows up as the gap between two turns.
    @MainActor
    private static func longestHold(over window: Duration, on clock: ContinuousClock) async -> Duration {
        let deadline = clock.now + window
        var longest = Duration.zero
        var last = clock.now
        while last < deadline {
            await Task.yield()
            let now = clock.now
            longest = max(longest, now - last)
            last = now
        }
        return longest
    }

    /// Where the reports land, and what the next one does.
    @MainActor
    private final class Arrivals {
        /// When the latest report landed, in both of the clocks it is read against.
        private(set) var last: (moment: HostTime, instant: ContinuousClock.Instant)?
        /// Run by the next report and then cleared, so a change reported twice cannot begin a
        /// second press.
        var next: (() -> Void)?

        func arrived() {
            last = (.now, ContinuousClock.now)
            let action = next
            next = nil
            action?()
        }
    }
}
