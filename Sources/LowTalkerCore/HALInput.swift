import AVFoundation
import CoreAudio
import Synchronization

/// The microphone, reached through CoreAudio's HAL audio unit.
///
/// AVAudioEngine is the obvious way to do this and it cannot meet the budget. Measured on
/// this Mac's built-in input, building an engine and starting it costs 315 ms from the
/// key going down - 475-630 ms for the first one in a process - against a
/// `AudioCapture.warmUpAllowance` of 100 ms, so under `shut`, where every press opens its
/// own microphone, every press came back `partial` and was refused. Keeping one engine
/// alive across presses does not fix it either: starts measured 43, 248 and 250 ms, and
/// the device stayed running after `stop()`, which lights the menu-bar indicator on a Mac
/// nobody is dictating to - the exact thing `shut` exists to prevent.
///
/// The same device through a HAL unit opens in 40 ms, ±2 ms, and goes dark on every stop.
/// What makes that possible is the split this type is named for: the expensive part of
/// reaching a microphone is per-process and is spent in `AudioComponentInstanceNew` and
/// `AudioUnitInitialize` (175 ms cold, 31 ms after), and neither of them opens a device.
/// Only `AudioOutputUnitStart` does. So an app that prepares while it is idle leaves a
/// press paying 40 ms, and shows no indicator for the preparing.
///
/// [LAW:effects-at-boundaries] Every CoreAudio call in the capture path is here, behind
/// `PreparedInput`, so the state machine in `AudioCapture` runs in tests against hardware
/// a test controls and on a CI machine with no microphone at all.
@MainActor
final class HALInput: PreparedInput {
    /// What the render callback reaches, and the only things touched on the audio thread.
    ///
    /// A class because the callback is a C function pointer that cannot capture: it is
    /// handed this by address, which is also why it must outlive every render, and why
    /// the unit is stopped before it is let go. [LAW:no-ambient-temporal-coupling]
    private final class Sink: @unchecked Sendable {
        /// Where a running unit's samples go. Empty between presses: the unit is stopped
        /// then, and a render that was already in flight has nowhere to put audio the
        /// speaker has let go of.
        private let target = Mutex<Target?>(nil)
        /// Touched on the audio thread, one render at a time - and by the main actor only
        /// while the unit is stopped, which is where `open()` resets the converter for the
        /// press it is about to begin. `AudioOutputUnitStop` returns with the IO thread
        /// quiesced, so the two never overlap; a lock here would put an acquisition in the
        /// render path to guard a call that cannot race it.
        nonisolated(unsafe) let converter: AudioClip.Converter
        nonisolated(unsafe) let buffer: AVAudioPCMBuffer
        nonisolated(unsafe) var unit: AudioUnit?

        struct Target {
            let appending: @Sendable ([Float], HostTime) -> Void
            /// Already hops to the main actor; the audio thread cannot wait for one.
            let onFailure: @Sendable (any Error) -> Void
        }

        init(converter: AudioClip.Converter, buffer: AVAudioPCMBuffer) {
            self.converter = converter
            self.buffer = buffer
        }

        func aim(at new: Target?) { target.withLock { $0 = new } }

        /// What CoreAudio calls on its own IO thread, as the C function pointer the unit
        /// takes. Reaches the sink it was handed the address of, and nothing else.
        ///
        /// It lives on the sink rather than inside `HALInput.init` because a closure takes
        /// the isolation of the context it was formed in: one written in a `@MainActor`
        /// member is inferred main-actor-isolated, and converting that to a C function
        /// pointer leaves a runtime isolation check in the thunk which traps the first time
        /// CoreAudio calls it - on the audio thread, which is the only thread that ever
        /// calls it. A press died on its first buffer and the crash named this closure.
        /// Nothing about a render is the main actor's, and this is where the type says so
        /// rather than leaving it to where the lines happen to sit.
        /// [LAW:no-ambient-temporal-coupling]
        static let callback: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
            Unmanaged<Sink>.fromOpaque(refCon).takeUnretainedValue()
                .render(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
        }

        /// One device buffer: rendered into our own memory, converted to pipeline
        /// samples, and handed over stamped with the capture time of its first sample.
        func render(
            flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
            timeStamp: UnsafePointer<AudioTimeStamp>,
            bus: UInt32,
            frames: UInt32
        ) -> OSStatus {
            guard let unit, let target = target.withLock({ $0 }) else { return noErr }
            // A device that asks for more than the slice it was initialized for would
            // overrun the buffer; refusing is the loud version of that.
            // [LAW:no-silent-failure]
            guard frames <= buffer.frameCapacity else {
                target.onFailure(AudioHardwareError.overlongSlice(frames: Int(frames), capacity: Int(buffer.frameCapacity)))
                return kAudio_ParamError
            }
            // How much of the buffer this render may fill, said before the call rather than
            // after it - which is the whole of it. Every `mDataByteSize` in the buffer list
            // is derived from `frameLength` at each access, so writing those byte sizes
            // directly wrote over values the next access recomputed: the list handed to the
            // render said zero bytes were available and the unit refused it with -50, on
            // the first buffer of every press. [LAW:one-source-of-truth] The length is the
            // fact and the byte sizes are its derivation, so the length is what gets set.
            buffer.frameLength = frames
            let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, buffer.mutableAudioBufferList)
            guard status == noErr else {
                target.onFailure(AudioHardwareError.renderFailed(status))
                return status
            }
            do {
                // Parsed before the buffer is converted, not alongside it: arguments
                // evaluate left to right, so converting first would feed this buffer into
                // the resampler and then throw the output away when the stamp turns out to
                // be unplaceable - leaving the filter primed by audio nobody has, and a
                // seam in the middle of the press. [LAW:parse-dont-validate]
                let captured = try HostTime(timeStamp.pointee)
                target.appending(try converter.convert(buffer), captured)
            } catch {
                target.onFailure(error)
            }
            return noErr
        }
    }

    private let unit: AudioUnit
    private let sink: Sink
    /// The device this was prepared against. A prepared input is bound to one device, so
    /// a default-input change is answered by preparing another rather than by re-pointing
    /// this one. [LAW:one-source-of-truth] `AudioCapture` is the one place that knows the
    /// device changed, and asking it for a fresh input is how that knowledge arrives here.
    let device: AudioObjectID
    /// Listeners on the bound device, dropped with the input.
    private var watches: [Disposal] = []

    /// Everything a press should not have to pay for: the component, the device binding,
    /// the format, the converter and the buffers, all the way to `AudioUnitInitialize`.
    /// No device is opened here, and macOS lights no indicator for it.
    init() throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioHardwareError.noInputComponent
        }
        var instance: AudioUnit?
        try AudioHardwareError.check(AudioComponentInstanceNew(component, &instance), AudioHardwareError.componentUnavailable)
        guard let unit = instance else { throw AudioHardwareError.componentUnavailable(noErr) }

        // Everything below configures `unit` through locals, and the stored properties are
        // assigned only once the last throwing call has succeeded. Swift runs a class's
        // `deinit` for a throwing initializer only when every stored property was already
        // assigned, so deferring them keeps "init threw" and "deinit ran" mutually
        // exclusive: the catch here is the one place a half-built unit is disposed, and it
        // cannot double-free one `deinit` is also about to take. Assigning as we went
        // leaked a component per attempt instead - `defaultInput()` below throws on any Mac
        // with no microphone, which is the case `UnreachableInput` exists to carry, and
        // every retry prepared another. [LAW:single-enforcer]
        let device: AudioObjectID
        let sink: Sink
        do {
            // Input on bus 1, output off: this unit captures and never plays.
            var enable: UInt32 = 1
            try AudioHardwareError.check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, Self.inputBus, &enable, UInt32(MemoryLayout<UInt32>.size)),
                AudioHardwareError.inputUnavailable
            )
            var disable: UInt32 = 0
            try AudioHardwareError.check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size)),
                AudioHardwareError.inputUnavailable
            )

            var binding = try Self.defaultInput()
            try AudioHardwareError.check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &binding, UInt32(MemoryLayout<AudioObjectID>.size)),
                AudioHardwareError.inputUnavailable
            )
            device = binding

            // What the device delivers, which decides what the converter converts from.
            var source = AudioStreamBasicDescription()
            var sourceSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try AudioHardwareError.check(
                AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, Self.inputBus, &source, &sourceSize),
                AudioHardwareError.inputUnavailable
            )
            // Float samples, one buffer per channel: the shape `AudioClip.Converter` reads and
            // the shape a render can be pointed at channel by channel. The unit converts the
            // device's own encoding into it, so nothing here has to know what that was.
            var client = AudioStreamBasicDescription(
                mSampleRate: source.mSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
                mChannelsPerFrame: source.mChannelsPerFrame,
                mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
                mReserved: 0
            )
            try AudioHardwareError.check(
                AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, Self.inputBus, &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                AudioHardwareError.inputUnavailable
            )
            guard let format = AVAudioFormat(streamDescription: &client) else {
                throw AudioClipError.unconvertibleFormat(sampleRate: client.mSampleRate, channels: client.mChannelsPerFrame)
            }

            // The largest slice this unit may ask for, which is what the render buffer has to
            // be able to hold. Read rather than assumed: a render bigger than the buffer is a
            // crash, and the number is the unit's to state.
            var slice: UInt32 = 0
            var sliceSize = UInt32(MemoryLayout<UInt32>.size)
            try AudioHardwareError.check(
                AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &slice, &sliceSize),
                AudioHardwareError.inputUnavailable
            )
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(slice)) else {
                throw AudioClipError.bufferAllocationFailed
            }

            let built = Sink(converter: try AudioClip.Converter(from: format), buffer: buffer)
            built.unit = unit

            var callback = AURenderCallbackStruct(
                inputProc: Sink.callback,
                inputProcRefCon: Unmanaged.passUnretained(built).toOpaque()
            )
            try AudioHardwareError.check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                AudioHardwareError.inputUnavailable
            )

            // The last of the per-process cost, and still no device open.
            try AudioHardwareError.check(AudioUnitInitialize(unit), AudioHardwareError.inputUnavailable)
            sink = built
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }

        self.unit = unit
        self.device = device
        self.sink = sink
    }

    /// Opens the device. What a press pays.
    func open(
        appending: @escaping @Sendable ([Float], HostTime) -> Void,
        onFailure: @escaping @MainActor (any Error) -> Void,
        onConfigurationChange: @escaping @MainActor () -> Void
    ) throws -> Disposal {
        sink.aim(at: Sink.Target(
            appending: appending,
            // The audio thread cannot wait for the main actor, so the report is posted
            // rather than made. [LAW:no-ambient-temporal-coupling]
            onFailure: { error in Task { @MainActor in onFailure(error) } }
        ))
        do {
            // A press is its own stream: the device was closed between this open and the
            // last, so the resampler starts from nothing rather than carrying the previous
            // press's tail into the head of this one. [LAW:one-source-of-truth]
            sink.converter.reset()
            // This unit is bound to one device, so a device that goes away or changes shape
            // under it is the capture's cue to launch another. A switch of the system
            // default input leaves both of these quiet and is `AudioCapture`'s to see.
            //
            // Appended one at a time, and inside this `do`, so a second registration that
            // throws still leaves the first disposable.
            //
            // Both only watch between here and `close()`. Under `shut` that is the length of
            // a press, so a device that is still the default and renegotiates its format
            // while the microphone rests - a headset changing codec - is heard by nothing,
            // and the next press opens against the format this was prepared for. The unit
            // still converts to the format we asked it for, so that press is resampled twice
            // rather than wrong, which is why this is written down here and tracked in
            // low-privacy-o1z.aa1 rather than paid for on every press.
            watches.append(try watch(kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal, onConfigurationChange))
            watches.append(try watch(kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput, onConfigurationChange))
            try AudioHardwareError.check(AudioOutputUnitStart(unit), AudioHardwareError.inputUnavailable)
        } catch {
            close()
            throw error
        }
        return { [weak self] in self?.close() }
    }

    /// Gives the device back and leaves the input prepared, so the next press opens it at
    /// the prepared price. [LAW:single-enforcer] Every way this input stops comes through
    /// here, including the one `deinit` takes and the one an `open()` that failed partway
    /// takes.
    ///
    /// Every step is idempotent - stopping a stopped unit, clearing a cleared target and
    /// disposing an empty list all do nothing - so this needs no flag saying whether the
    /// device is open. It had one, and because it was set only after a successful start,
    /// it made this a no-op on exactly the path that had listeners to unwind.
    /// [LAW:polishing-by-subtraction]
    private func close() {
        // [LAW:no-silent-failure] exception: this is the one CoreAudio call here whose
        // status is dropped, and it is dropped because nothing this function can reach
        // could act on it - `deinit` and the unwind of a failed `open()` both arrive here
        // with no caller to throw to. What it costs is written down in low-privacy-o1z.pr2:
        // a stop that failed may leave the device running and the indicator lit. Both ways
        // of surfacing it need a status vocabulary this Mac has not been made to produce -
        // a precondition would crash on whatever an unplugged device returns, which is this
        // call's likeliest failure and `replaceEngine`'s ordinary path.
        AudioOutputUnitStop(unit)
        // After the stop, so a render already in flight still has somewhere to put the
        // audio it holds rather than dropping it on the floor.
        sink.aim(at: nil)
        watches.forEach { $0() }
        watches = []
    }

    /// The scope is the caller's because it is the property's, not this function's:
    /// `kAudioObjectPropertyScopeGlobal` is a scope like any other rather than a wildcard,
    /// and a listener whose address names a different scope than the notification is
    /// published on is never called. Registering an input device's stream format globally
    /// succeeds and then hears nothing, which is the quietest way this could be wrong.
    private func watch(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, _ onChange: @escaping @MainActor () -> Void) throws -> Disposal {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { onChange() } }
        let device = device
        try AudioHardwareError.check(
            AudioObjectAddPropertyListenerBlock(device, &address, .main, listener),
            AudioHardwareError.deviceWatchFailed
        )
        return {
            var removing = address
            let status = AudioObjectRemovePropertyListenerBlock(device, &removing, .main, listener)
            // A device that has been unplugged takes its listeners with it, which is the
            // ordinary way this one ends and not a fault.
            precondition(
                status == noErr || status == kAudioHardwareBadObjectError,
                "CoreAudio refused to remove a listener it added (status \(status))"
            )
        }
    }

    /// Which device a press would open. Nonisolated because reading it touches nothing this
    /// class owns, and `MicrophoneIndicator` asks the same question off the main actor: what
    /// the indicator shows is a fact about that device, so the two must not be free to
    /// disagree about which one it is. [LAW:one-source-of-truth]
    nonisolated static func defaultInput() throws -> AudioObjectID {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try AudioHardwareError.check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device),
            AudioHardwareError.noDefaultInput
        )
        guard device != kAudioObjectUnknown else { throw AudioHardwareError.noDefaultInput(noErr) }
        return device
    }

    private static let inputBus: UInt32 = 1

    deinit {
        // The unit is stopped before the sink it renders into is let go: a render already
        // under way holds a pointer to it. `close` is idempotent, so a disposal that
        // already ran leaves nothing for this to do.
        MainActor.assumeIsolated {
            close()
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
    }
}
