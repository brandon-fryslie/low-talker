import AVFoundation
import CoreAudio

/// Gives back something the hardware handed out: an engine, a listener. Called once.
public typealias Disposal = @MainActor () -> Void

/// A microphone that has paid everything it can pay before being opened.
///
/// Preparing one takes no device: nothing is captured and macOS lights no indicator until
/// `open`. That is why this is a value rather than a step inside `open`: reaching a
/// microphone costs far more than opening one already reached, and none of the reaching
/// opens a device, so an app that prepares while it is idle leaves a press paying only the
/// opening - which is what lets `shut` keep both the closed microphone and the head of the
/// first word. What each part costs is measured in `HALInput`, where the split is made.
///
/// [LAW:types-are-the-program] Prepared and open are two facts about the microphone, and
/// this type carries the first: a press cannot reach a device nothing prepared, and
/// preparing cannot open one. The second is the `Disposal` `open` hands back.
@MainActor
public protocol PreparedInput {
    /// Opens the device. Every buffer it captures arrives at `appending` as pipeline
    /// samples with the host time its first sample was captured at, on the audio service
    /// queue. Reports on the main actor: `onFailure` when a buffer could not be converted
    /// or placed in time, `onConfigurationChange` when the device this was prepared
    /// against has gone or changed shape underneath it. Throws when the device cannot
    /// feed the pipeline - including when there was nothing to prepare, which is the one
    /// moment that matters and the one place every caller already answers it.
    /// [LAW:single-enforcer]
    ///
    /// The disposal gives the device back and leaves the input prepared, so the next
    /// press opens it at the prepared price rather than at the first one's.
    func open(
        appending: @escaping @Sendable ([Float], HostTime) -> Void,
        onFailure: @escaping @MainActor (any Error) -> Void,
        onConfigurationChange: @escaping @MainActor () -> Void
    ) throws -> Disposal
}

/// What the system does for capture: ready a microphone, open it, and say when the
/// default input device changes.
///
/// [LAW:effects-at-boundaries] Every one of these is an effect against CoreAudio. They
/// sit behind this seam so the state machine above them (which microphone is open, when
/// to open another, what an outage was) runs in tests against hardware a test controls,
/// and on a CI machine that has no microphone at all.
@MainActor
public protocol AudioHardware {
    /// Readies a microphone without opening it.
    ///
    /// Never throws, and that is deliberate: what can go wrong about reaching a
    /// microphone is not a thing the resting state can answer. Capture rests between
    /// presses, and a rest that could fail would have to decide whether a Mac with no
    /// microphone is a failed capture - which would leave a device change relaunching an
    /// engine a config asked to keep shut. So a preparation that could not happen is
    /// carried in the input and thrown when a press opens it. [LAW:no-silent-failure]
    func prepareInput() -> any PreparedInput

    /// Calls `onChange` on the main actor each time the system default input device
    /// changes, until disposed.
    func watchDefaultInput(_ onChange: @escaping @MainActor () -> Void) throws -> Disposal
}

public enum AudioHardwareError: Error, Equatable, CustomStringConvertible {
    case defaultInputWatchFailed(OSStatus)
    /// A listener on one bound device - its liveness or its stream format - rather than on
    /// which device is the default. Two different subsystems, and a person reading the
    /// failure of a press is the one who has to tell them apart.
    case deviceWatchFailed(OSStatus)
    /// A buffer arrived with no host clock behind its time.
    case bufferWithoutTime
    case noInputComponent
    case componentUnavailable(OSStatus)
    case inputUnavailable(OSStatus)
    case noDefaultInput(OSStatus)
    case renderFailed(OSStatus)
    /// The device asked to hand over more audio at once than the unit said it would.
    case overlongSlice(frames: Int, capacity: Int)

    public var description: String {
        switch self {
        case .defaultInputWatchFailed(let status): "CoreAudio refused a listener on the default input device (status \(status))"
        case .deviceWatchFailed(let status): "CoreAudio refused a listener on the input device this microphone is bound to (status \(status))"
        case .bufferWithoutTime: "the input device delivered a buffer with no host time; nothing can say when its samples were captured"
        case .noInputComponent: "this Mac has no HAL audio unit to capture through"
        case .componentUnavailable(let status): "the HAL audio unit could not be instantiated (status \(status))"
        case .inputUnavailable(let status): "the input device would not be made ready to capture (status \(status))"
        case .noDefaultInput(let status): "this Mac has no default input device (status \(status))"
        case .renderFailed(let status): "the input device refused to hand over a buffer it had announced (status \(status))"
        case .overlongSlice(let frames, let capacity): "the input device asked to hand over \(frames) frames at once, past the \(capacity) it was prepared for"
        }
    }

    /// [LAW:no-silent-failure] The one place an OSStatus becomes a thrown error, so no
    /// call in the capture path can be checked by eye and then not checked.
    static func check(_ status: OSStatus, _ fault: (OSStatus) -> AudioHardwareError) throws {
        guard status == noErr else { throw fault(status) }
    }
}

extension HostTime {
    /// [LAW:parse-dont-validate] The one place a CoreAudio stamp becomes a host time.
    /// It counts the machine's raw ticks rather than nanoseconds, and CoreAudio may hand
    /// out a time with no host clock behind it at all - samples that cannot be placed in
    /// time are samples no session can be cut from, so that is a failed engine rather
    /// than a guess. [LAW:no-silent-failure]
    init(_ when: AVAudioTime) throws {
        guard when.isHostTimeValid else { throw AudioHardwareError.bufferWithoutTime }
        self.init(uptime: .seconds(AVAudioTime.seconds(forHostTime: when.hostTime)))
    }

    init(_ stamp: AudioTimeStamp) throws {
        guard stamp.mFlags.contains(.hostTimeValid) else { throw AudioHardwareError.bufferWithoutTime }
        self.init(uptime: .seconds(AVAudioTime.seconds(forHostTime: stamp.mHostTime)))
    }
}

public struct SystemAudioHardware: AudioHardware {
    public init() {}

    public func prepareInput() -> any PreparedInput {
        do { return try HALInput() }
        // Carried rather than raised: see `AudioHardware.prepareInput`.
        catch { return UnreachableInput(fault: error) }
    }

    public func watchDefaultInput(_ onChange: @escaping @MainActor () -> Void) throws -> Disposal {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        // Delivered on the main queue, which is the main actor.
        let listener: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { onChange() } }
        var adding = address
        try AudioHardwareError.check(
            AudioObjectAddPropertyListenerBlock(system, &adding, .main, listener),
            AudioHardwareError.defaultInputWatchFailed
        )
        return {
            var removing = address
            let status = AudioObjectRemovePropertyListenerBlock(system, &removing, .main, listener)
            precondition(status == noErr, "CoreAudio refused to remove the default input listener it added (status \(status))")
        }
    }
}

/// A microphone that could not be readied, holding the reason until a press asks for it.
///
/// [LAW:types-are-the-program] The failure is a value the input carries rather than a
/// state capture has to represent, so nothing above has to hold "prepared, or else" - and
/// the press that needs a microphone is told exactly why there is none.
private struct UnreachableInput: PreparedInput {
    let fault: any Error

    func open(
        appending: @escaping @Sendable ([Float], HostTime) -> Void,
        onFailure: @escaping @MainActor (any Error) -> Void,
        onConfigurationChange: @escaping @MainActor () -> Void
    ) throws -> Disposal {
        throw fault
    }
}
