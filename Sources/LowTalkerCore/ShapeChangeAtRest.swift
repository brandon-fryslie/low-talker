import CoreAudio

/// Whether a microphone that has been readied and then left alone is told when the device
/// under it changes shape.
///
/// A prepared input is bound to one device and fixes its client format, its render buffer and
/// its converter against the shape that device had when it was readied. That stays true for
/// as long as the input exists and not only while a press holds it open, so the watch on it
/// has to last that long too. It did not: both device watches were registered in `open()` and
/// dropped in `close()`, which under the `shut` resting mode is the length of a press. A
/// device that stayed the default while renegotiating its format between presses - a headset
/// changing codec is the ordinary way - was heard by nobody, and the next press opened against
/// the shape before it and resampled the utterance twice.
///
/// No suite can reach that. `AudioCapture`'s tests run against hardware a test controls, and a
/// fake can be told to report anything, including that it was heard on a build where CoreAudio
/// would have said nothing. What is actually in question is whether CoreAudio delivers a
/// stream-format notification to a listener on a device this process has readied and never
/// opened, and only a device can answer it. So this is that answer, taken the way
/// `IndicatorAcrossHold` takes its own: one command, on the Mac the claim is about, reporting
/// its own verdict. [LAW:verifiable-goals]
///
/// It says whether the report arrived, not what capture did with it. What `AudioCapture` owes
/// a stale input - give up a running engine, ready another, ignore one that speaks for an
/// input already replaced - is a state machine, and its suite is where that is checked.
public struct ShapeChangeAtRest: Sendable, CustomStringConvertible {
    /// What became of the report the readied microphone was owed.
    public enum Report: Sendable, Equatable, CustomStringConvertible {
        /// It arrived, which is the promise: the watch outlives the press.
        case heard
        /// Nothing arrived before the wait ran out.
        case never

        public var description: String {
            switch self {
            case .heard: "heard"
            case .never: "not heard"
            }
        }
    }

    /// A way this reading can come back wrong, and what holding it means.
    ///
    /// [LAW:one-source-of-truth] Each fault's meaning is written once, here, and the report's
    /// lines are printed from it - so there is no second copy of what an unheard report says
    /// about the code to drift from this one.
    public enum Fault: Sendable, Equatable, CustomStringConvertible {
        /// The device changed shape and the readied microphone never heard about it.
        case unheard
        /// This reading moved the device and could not move it back.
        case leftReshaped

        public var description: String {
            switch self {
            case .unheard:
                """
                the readied microphone is not watching the device it is bound to: the watch is registered where a \
                press begins rather than where the binding is made, so the stretch between presses is unwatched and \
                the next press opens a converter, a client format and a render buffer against a shape the device has \
                left behind. Raise --wait before believing this on a Mac that may be slow to publish the change \
                rather than deaf to it
                """
            case .leftReshaped:
                """
                the device was moved to take this reading and would not go back, so this Mac has been left at a \
                sample rate its owner did not choose. Audio MIDI Setup is where a person puts it back by hand
                """
            }
        }
    }

    /// The device the readied input turned out to be bound to, which is CoreAudio's answer
    /// and not the one the preparation asked for.
    public let device: AudioObjectID
    /// The nominal rate the input was readied against.
    public let readiedAt: Double
    /// The nominal rate the device was moved to while the microphone rested.
    public let movedTo: Double
    public let report: Report
    /// The rate the device was left at, read back off it rather than taken from the status of
    /// the call that asked. [FRAMING:representation] The territory, not the map.
    public let leftAt: Double

    public init(device: AudioObjectID, readiedAt: Double, movedTo: Double, report: Report, leftAt: Double) {
        self.device = device
        self.readiedAt = readiedAt
        self.movedTo = movedTo
        self.report = report
        self.leftAt = leftAt
    }

    /// Every way this reading came back wrong. Empty is the promise kept and the Mac put back.
    ///
    /// [LAW:dataflow-not-control-flow] Both are asked the same way and neither skips the
    /// other, so a reading that broke twice says so twice - an operator told only about the
    /// first would put it right and re-run into the second.
    public var faults: [Fault] {
        [(Fault.unheard, report == .never), (Fault.leftReshaped, leftAt != readiedAt)]
            .filter(\.1)
            .map(\.0)
    }

    public var kept: Bool { faults.isEmpty }

    /// The reading on one line, and a line for each fault saying what it means. A Mac that
    /// kept the promise has nothing to explain, so it prints the one line.
    public var description: String {
        (["device \(device): readied at \(readiedAt) Hz, moved to \(movedTo) Hz while resting, \(report), left at \(leftAt) Hz"]
            + faults.map { "\($0)" })
            .joined(separator: "\n")
    }

    /// Readies a microphone on this Mac, changes the shape of the device it bound to while
    /// nothing has it open, and reports whether the readied microphone heard that.
    ///
    /// [LAW:single-enforcer] Every reading of this kind comes through here, so the refusals
    /// are written once. Two of them: a device something else is already running cannot be
    /// moved without moving it under that recording, and a device that offers one shape has no
    /// change to make - a reading taken anyway would be an instrument answering a question it
    /// never managed to put. [LAW:no-silent-failure]
    ///
    /// The input is a `HALInput` rather than one `SystemAudioHardware` prepared, and
    /// deliberately: that path turns a preparation that could not happen into an input which
    /// throws at the press, because resting has no answer for a failure. A reading does, and
    /// it is to throw here rather than time out at the wait and call the Mac deaf.
    ///
    /// Nothing here reads the indicator, because nothing here needs to: `HALInput.init` ends
    /// by refusing a preparation that left the device running on this process's account, so
    /// "readying opened nothing" is enforced where it is done rather than re-checked here.
    @MainActor
    public static func measure(waiting wait: Duration) async throws -> ShapeChangeAtRest {
        guard try MicrophoneIndicator.read() == .dark else { throw MicrophoneAlreadyRunning() }
        let arrival = Arrival()
        let input = try HALInput(onStale: { arrival.arrived() })
        let device = input.device
        let readiedAt = try nominalRate(of: device)
        let movedTo = try otherRate(of: device, than: readiedAt)

        try move(device, to: movedTo)
        // The whole reading is this wait. CoreAudio publishes the change asynchronously, so
        // the bound is a fact about the hardware rather than a sleep hiding a race: a report
        // that has not arrived by the deadline is what an unwatched device looks like, and
        // `--wait` is where an operator says how long this Mac gets.
        // [LAW:no-ambient-temporal-coupling]
        try await Task.sleep(for: wait)
        let report = arrival.report

        // [LAW:no-silent-failure] exception: the status of the ask is dropped because the
        // read-back below answers the same question better, and because a throw here would
        // take the reading with it - leaving an operator holding a moved Mac and no report.
        // The move that would not go back is reported as a fault instead.
        try? move(device, to: readiedAt)
        try await Task.sleep(for: wait)

        // The input is what holds the watch, and a reading that let it go before the report
        // arrived would be measuring its own deinit. Nothing above uses it after the
        // preparation, so this is what keeps it standing until the reading is taken.
        withExtendedLifetime(input) {}
        return ShapeChangeAtRest(
            device: device,
            readiedAt: readiedAt,
            movedTo: movedTo,
            report: report,
            leftAt: try nominalRate(of: device)
        )
    }

    /// Where the report lands. A class because the listener and the wait below it have to
    /// reach the same one, and `@MainActor` because that is where `HALInput` calls back.
    @MainActor
    private final class Arrival {
        private(set) var report = Report.never

        func arrived() { report = .heard }
    }

    /// A shape this device offers that is not the one it is in.
    ///
    /// The change has to be one the device will take: a rate it does not advertise is refused,
    /// and a refused change is a question never put rather than an answer about watching.
    private static func otherRate(of device: AudioObjectID, than rate: Double) throws -> Double {
        guard let other = try rates(of: device).map(\.mMinimum).first(where: { $0 != rate }) else {
            throw DeviceKeepsOneShape(device: device, rate: rate)
        }
        return other
    }

    private static func rates(of device: AudioObjectID) throws -> [AudioValueRange] {
        var address = shape(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        try AudioHardwareError.check(
            AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size),
            AudioHardwareError.deviceShapeUnreadable
        )
        var ranges = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        try AudioHardwareError.check(
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ranges),
            AudioHardwareError.deviceShapeUnreadable
        )
        return ranges
    }

    private static func nominalRate(of device: AudioObjectID) throws -> Double {
        var rate = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        var address = shape(kAudioDevicePropertyNominalSampleRate)
        try AudioHardwareError.check(
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate),
            AudioHardwareError.deviceShapeUnreadable
        )
        return rate
    }

    private static func move(_ device: AudioObjectID, to rate: Double) throws {
        var rate = rate
        var address = shape(kAudioDevicePropertyNominalSampleRate)
        try AudioHardwareError.check(
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &rate),
            AudioHardwareError.deviceShapeUnchangeable
        )
    }

    /// Global scope, where a device's sample rate lives - the rate is the device's, not one
    /// stream's, which is why changing it is what a whole device renegotiating looks like.
    /// The input-scoped `kAudioDevicePropertyStreamFormat` this moves is the one `HALInput`
    /// watches, and a scope that named the wrong one would read nothing and say so quietly.
    private static func shape(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

/// The default input device offers exactly one shape, so nothing can change it into another.
///
/// [LAW:no-silent-failure] Refused rather than reported as a promise kept: a reading taken
/// here would wait out its deadline against a device that was never asked to change, hear
/// nothing, and call that deafness - which is the one way this instrument could hand back a
/// failing verdict for code that is right.
public struct DeviceKeepsOneShape: Error, CustomStringConvertible {
    public let device: AudioObjectID
    public let rate: Double

    public var description: String {
        """
        device \(device) offers only \(rate) Hz, so there is no shape to change it to and no reading to take here. \
        A device with more than one - a USB interface, or a Bluetooth headset, which renegotiates on its own and is \
        the reproduction this was written for - has to be the default input for this to have a question to ask
        """
    }
}
