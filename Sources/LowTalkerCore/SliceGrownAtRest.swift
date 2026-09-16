import CoreAudio
import Synchronization

/// Whether a press still hears a device whose IO buffer grew while the microphone rested.
///
/// A readied microphone waits many presses to be opened under `shut`, and the slices its device
/// hands over can grow in the meantime. The HAL unit follows the device without being
/// initialized again: measured on this Mac for low-privacy-o1z.c0p, moving the built-in
/// microphone's IO buffer from 512 frames to 4096 under a prepared, stopped unit handed the
/// press that followed 4096-frame slices, which `AudioUnitRender` filled with `noErr`. So the
/// only thing between that press and its audio is the buffer it renders into, which is what
/// this reads. The move and the press are taken back to back, with no wait between them: a
/// buffer sized by anything that has to catch up with the device fails here whenever it has
/// not caught up yet.
///
/// The IO buffer size is per process - measured the same day: another process holding the same
/// device at 4096 left this one reading 512 - so this reading moves nothing but itself, and
/// nothing is put back: the size ends with the process that asked for it. It is also why no
/// other app can do this to LowTalker; what can is the device reconfiguring on its own.
///
/// No suite can reach it, for the reason `ShapeChangeAtRest` gives: a fake would report
/// whatever it was told. [LAW:verifiable-goals]
public struct SliceGrownAtRest: Sendable, CustomStringConvertible {
    /// The device the readied input turned out to be bound to.
    public let device: AudioObjectID
    /// The IO buffer, in frames, the input was readied against.
    public let readiedAt: UInt32
    /// The IO buffer, in frames, the device was moved to while the microphone rested.
    public let grownTo: UInt32
    /// Buffers the press delivered.
    public let delivered: Int
    /// The first failure the press reported, in its own words. Absent is a press that reported
    /// none.
    public let failure: String?

    public init(device: AudioObjectID, readiedAt: UInt32, grownTo: UInt32, delivered: Int, failure: String?) {
        self.device = device
        self.readiedAt = readiedAt
        self.grownTo = grownTo
        self.delivered = delivered
        self.failure = failure
    }

    /// A press that delivered audio and reported nothing wrong. Both halves, because a press
    /// whose every render was refused delivers nothing and may still report - and one that
    /// reports nothing may still deliver nothing, which is the same lost utterance said
    /// quietly. [LAW:no-silent-failure]
    public var kept: Bool { failure == nil && delivered > 0 }

    public var description: String {
        let heard = "device \(device): readied at \(readiedAt) frames, grown to \(grownTo) while resting, press delivered \(delivered) buffers"
        guard !kept else { return heard }
        return """
            \(heard), \(failure ?? "and reported nothing")
            a press opened on a readied microphone lost its audio to a device slice larger than the buffer it renders into, \
            so that buffer was sized to something smaller than what the device offered when the press opened
            """
    }

    /// Readies a microphone on this Mac, grows this process's IO buffer on the device it bound
    /// to, opens it for `hold`, and reports what the press heard.
    ///
    /// Refuses a device already running for the reason `IndicatorAcrossHold` does, and one whose
    /// IO buffer cannot grow past where it was readied because there is no question to put to
    /// it. [LAW:no-silent-failure]
    @MainActor
    public static func measure(holding hold: Duration) async throws -> SliceGrownAtRest {
        guard try MicrophoneIndicator.read() == .dark else { throw MicrophoneAlreadyRunning() }
        let input = HALInput(onStale: {})
        let device = try input.device
        let readiedAt = try ioBuffer(of: device)
        let grownTo = try largestIOBuffer(of: device)
        guard grownTo > readiedAt else { throw DeviceKeepsOneSlice(device: device, frames: readiedAt) }
        try grow(device, to: grownTo)

        let press = Press()
        let close = try input.open(appending: { _, _ in press.delivered.add(1, ordering: .relaxed) }, onFailure: press.failed)
        // Failures are posted to the main actor, and this sleep is where they land.
        try await Task.sleep(for: hold)
        // The disposal holds the input weakly and nothing else here uses it after `open`, so
        // this is what keeps its unit running through the hold rather than to its last use.
        withExtendedLifetime(input) { close() }
        return SliceGrownAtRest(
            device: device,
            readiedAt: readiedAt,
            grownTo: grownTo,
            delivered: press.delivered.load(ordering: .relaxed),
            failure: press.failure
        )
    }

    /// What a press delivered, counted on the audio thread, and what it reported, on the main
    /// actor where `HALInput` reports it.
    @MainActor
    private final class Press {
        nonisolated let delivered = Atomic<Int>(0)
        private(set) var failure: String?

        func failed(_ error: any Error) { failure = failure ?? "\(error)" }
    }

    private static func ioBuffer(of device: AudioObjectID) throws -> UInt32 {
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = io(kAudioDevicePropertyBufferFrameSize)
        try AudioHardwareError.check(
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &frames),
            AudioHardwareError.deviceShapeUnreadable
        )
        return frames
    }

    private static func largestIOBuffer(of device: AudioObjectID) throws -> UInt32 {
        var range = AudioValueRange(mMinimum: 0, mMaximum: 0)
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        var address = io(kAudioDevicePropertyBufferFrameSizeRange)
        try AudioHardwareError.check(
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &range),
            AudioHardwareError.deviceShapeUnreadable
        )
        return UInt32(range.mMaximum)
    }

    private static func grow(_ device: AudioObjectID, to frames: UInt32) throws {
        var frames = frames
        var address = io(kAudioDevicePropertyBufferFrameSize)
        try AudioHardwareError.check(
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames),
            AudioHardwareError.deviceShapeUnchangeable
        )
    }

    private static func io(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}

/// The default input device's IO buffer is already as large as it offers, so nothing can grow
/// it past the size a microphone was readied against. [LAW:no-silent-failure] Refused rather
/// than reported kept: a press at the size it was readied for asks nothing about growth.
public struct DeviceKeepsOneSlice: Error, CustomStringConvertible {
    public let device: AudioObjectID
    public let frames: UInt32

    public var description: String {
        "device \(device) already hands over its largest IO buffer, \(frames) frames, so there is no larger slice to grow it to and no reading to take here"
    }
}
