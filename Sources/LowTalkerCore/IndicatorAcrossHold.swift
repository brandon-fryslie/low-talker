/// What the microphone indicator did across one hold, and whether that is what this app
/// promises: dark while nobody is dictating, lit for the length of a hold, dark again when
/// it ends.
///
/// Those three are facts about a device and a menu bar, and no test can reach them - every
/// `AudioCapture` test runs against hardware a test controls, and CI has no microphone at
/// all. So they were checked by hand, with binaries written for one run and then deleted,
/// and what survived was a sentence in a commit message: once a sentence claiming presses
/// came back whole, in a message whose own last line admitted none had run on a Mac. This
/// is the reading that message should have carried - one command, on the Mac the claim is
/// about, reporting its own verdict. [LAW:verifiable-goals]
///
/// It says what the device did, not what was heard. A device that ran and handed over
/// nothing reads as `lit` here, correctly, and `lowtalker record` is what says whether the
/// audio came back whole.
public struct IndicatorAcrossHold: Sendable, CustomStringConvertible {
    /// A moment in a hold, and what the app promises the indicator shows at it.
    ///
    /// [LAW:one-source-of-truth] The promise is written down once, here. Readings are judged
    /// against this table and the report's lines are printed from it, so there is no second
    /// copy of "dark, lit, dark" anywhere to drift from this one.
    public enum Moment: Sendable, Equatable, CustomStringConvertible {
        /// A microphone readied and no press in flight, which is what the app is doing for
        /// all but a few seconds of the day.
        case atRest
        /// A press, still held.
        case duringHold
        /// The press let go.
        case afterHold

        public var description: String {
            switch self {
            case .atRest: "at rest"
            case .duringHold: "during the hold"
            case .afterHold: "after the hold"
            }
        }

        public var promised: MicrophoneIndicator {
            switch self {
            case .atRest: .dark
            case .duringHold: .lit
            case .afterHold: .dark
            }
        }

        /// What a broken promise here says about this Mac, which is the whole reason to take
        /// the reading rather than assert it. The three are three different faults with
        /// three different causes, and an operator holding `lit` where `dark` was promised
        /// should not have to work out which one they have.
        public var fault: String {
            switch self {
            case .atRest: "readying a microphone opened a device, so the split this rests on - reach a microphone without taking one - is gone, and the menu bar is lit on a Mac nobody has dictated to"
            case .duringHold: "the press opened no device the indicator follows: either nothing opened at all, or what opened is not the device that is now the default input"
            case .afterHold: "the press did not give the device back, which is the indicator left lit on a Mac nobody is dictating to that this set out to stop - unless something else opened the microphone while this ran, which coreaudiod's log will name and the refusal at the start could not see coming"
            }
        }
    }

    public struct Reading: Sendable, CustomStringConvertible {
        public let moment: Moment
        public let shown: MicrophoneIndicator

        public var kept: Bool { shown == moment.promised }

        public var description: String { "\(moment): \(shown)" }
    }

    /// The three readings, in the order they were taken.
    ///
    /// [LAW:types-are-the-program] The initializer below is the only way to make one, and it
    /// takes all three and labels each itself - so there is no report with two readings, or
    /// with one moment read twice, or with a reading nobody labelled.
    public let readings: [Reading]

    public init(atRest: MicrophoneIndicator, duringHold: MicrophoneIndicator, afterHold: MicrophoneIndicator) {
        readings = [
            Reading(moment: .atRest, shown: atRest),
            Reading(moment: .duringHold, shown: duringHold),
            Reading(moment: .afterHold, shown: afterHold),
        ]
    }

    /// Every reading that is not what was promised. Empty is the promise kept whole.
    public var broken: [Reading] { readings.filter { !$0.kept } }

    public var kept: Bool { broken.isEmpty }

    /// The readings on one line, and a line for each broken promise saying what it means.
    /// A Mac that kept the promise has nothing to explain, so it prints the one line.
    public var description: String {
        ([readings.map(\.description).joined(separator: ", ")]
            + broken.map { "\($0.moment): promised \($0.moment.promised), and \($0.moment.fault)" })
            .joined(separator: "\n")
    }

    /// Takes the three readings around one hold on this Mac, through the same capture the
    /// app runs and the resting mode the promise is about.
    ///
    /// [LAW:single-enforcer] Every reading taken off a Mac comes through here - the
    /// initializer above writes a report down, this is the only thing that goes and reads one
    /// - so the refusal is written once. A default input device already running before
    /// anything here has readied a microphone leaves nothing to read: the property says only
    /// that the device is running *somewhere*, so our hold cannot be told from the hold of
    /// whatever had it first, and three readings taken anyway would be an instrument
    /// answering a question it could not see. [LAW:no-silent-failure]
    ///
    /// The capture is the real one against the real hardware, and that is deliberate: an
    /// `AudioHardware` parameter here would let this run green on CI against the fake, which
    /// is a mock wearing a hardware check's name and would leave the promise exactly as
    /// unread as it was before.
    @MainActor
    public static func measure(holding hold: Duration, with grant: MicrophoneGrant) async throws -> IndicatorAcrossHold {
        guard try MicrophoneIndicator.read() == .dark else { throw MicrophoneAlreadyRunning() }
        let capture = AudioCapture()
        // `shut` whatever the config file says. It is the resting mode the promise is about,
        // and `open` is the user asking in writing for the opposite of it.
        try capture.start(grant, atRest: .shut)
        defer { capture.stop() }
        // Readied by `start` and opened by nothing yet.
        let atRest = try MicrophoneIndicator.read()
        let session = try capture.beginSession(at: .now)
        try await Task.sleep(for: hold)
        // Read at the end of the hold rather than at its start: a device that stopped partway
        // through is a press the speaker lost, and a reading taken at the open would call
        // that hold lit.
        let duringHold = try MicrophoneIndicator.read()
        // The clip is `lowtalker record`'s subject, not this one's. What is being read here is
        // what the device did, which no clip can say.
        _ = capture.endSession(session)
        return IndicatorAcrossHold(atRest: atRest, duringHold: duringHold, afterHold: try MicrophoneIndicator.read())
    }
}

/// Something already had the microphone when a reading of the indicator was about to begin.
///
/// [LAW:no-silent-failure] The refusal names where to look, because the property it is
/// refusing on cannot: "running somewhere" is the whole of what the indicator knows, and an
/// operator told only that much is left quitting apps one at a time. `coreaudiod` publishes
/// the pid with every change, and that log line is how the holder was found the first time
/// this refused - it was LowTalker.app, running a build from before the microphone learned
/// to close. Spelled `/usr/bin/log` because `log` is a zsh builtin and this Mac's shell is
/// zsh.
public struct MicrophoneAlreadyRunning: Error, CustomStringConvertible {
    public var description: String {
        """
        the default input device was already running before this readied anything, so there is no reading to take: \
        the indicator says only that some process on this Mac has a microphone open, and nothing here can tell that \
        hold from its own. coreaudiod names the process that started it - \
        /usr/bin/log show --last 5m --predicate 'eventMessage CONTAINS "PublishRecordingClientInfo: Report client"' \
        - and LowTalker.app is a candidate, being the very thing this reads for
        """
    }
}
