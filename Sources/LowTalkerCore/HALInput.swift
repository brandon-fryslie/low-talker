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
        /// Touched only on the audio thread, one render at a time.
        nonisolated(unsafe) let converter: AudioClip.Converter
        nonisolated(unsafe) let buffer: AVAudioPCMBuffer
        nonisolated(unsafe) var unit: AudioUnit?
        let bytesPerFrame: Int

        struct Target {
            let appending: @Sendable ([Float], HostTime) -> Void
            /// Already hops to the main actor; the audio thread cannot wait for one.
            let onFailure: @Sendable (any Error) -> Void
        }

        init(converter: AudioClip.Converter, buffer: AVAudioPCMBuffer, bytesPerFrame: Int) {
            self.converter = converter
            self.buffer = buffer
            self.bytesPerFrame = bytesPerFrame
        }

        func aim(at new: Target?) { target.withLock { $0 = new } }

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
            let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            // Each channel is its own buffer in a non-interleaved format, and each one
            // must say how much of it this render may fill rather than how much it holds.
            for channel in 0..<list.count {
                list[channel].mDataByteSize = frames * UInt32(bytesPerFrame)
            }
            let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, buffer.mutableAudioBufferList)
            guard status == noErr else {
                target.onFailure(AudioHardwareError.renderFailed(status))
                return status
            }
            buffer.frameLength = frames
            do {
                target.appending(try converter.convert(buffer), try HostTime(timeStamp.pointee))
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
    private var isOpen = false

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
        self.unit = unit

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

        var device = try Self.defaultInput()
        self.device = device
        try AudioHardwareError.check(
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioObjectID>.size)),
            AudioHardwareError.inputUnavailable
        )

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

        sink = Sink(
            converter: try AudioClip.Converter(from: format),
            buffer: buffer,
            bytesPerFrame: MemoryLayout<Float>.size
        )
        sink.unit = unit

        var callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timeStamp, bus, frames, _ in
                Unmanaged<Sink>.fromOpaque(refCon).takeUnretainedValue()
                    .render(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
            },
            inputProcRefCon: Unmanaged.passUnretained(sink).toOpaque()
        )
        try AudioHardwareError.check(
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
            AudioHardwareError.inputUnavailable
        )

        // The last of the per-process cost, and still no device open.
        try AudioHardwareError.check(AudioUnitInitialize(unit), AudioHardwareError.inputUnavailable)
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
        // The device going away or changing shape under a running unit is what
        // AVAudioEngine reported as a configuration change, and it is the same event:
        // this unit is bound to one device, so the capture above has to launch another.
        watches = [
            try watch(kAudioDevicePropertyDeviceIsAlive, onConfigurationChange),
            try watch(kAudioDevicePropertyStreamFormat, onConfigurationChange),
        ]
        do {
            try AudioHardwareError.check(AudioOutputUnitStart(unit), AudioHardwareError.inputUnavailable)
        } catch {
            close()
            throw error
        }
        isOpen = true
        return { [weak self] in self?.close() }
    }

    /// Gives the device back and leaves the input prepared, so the next press opens it at
    /// the prepared price. [LAW:single-enforcer] Every way this input stops comes through
    /// here, including the one `deinit` takes.
    private func close() {
        guard isOpen else { return }
        isOpen = false
        AudioOutputUnitStop(unit)
        // After the stop, so a render already in flight still has somewhere to put the
        // audio it holds rather than dropping it on the floor.
        sink.aim(at: nil)
        watches.forEach { $0() }
        watches = []
    }

    private func watch(_ selector: AudioObjectPropertySelector, _ onChange: @escaping @MainActor () -> Void) throws -> Disposal {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { onChange() } }
        let device = device
        try AudioHardwareError.check(
            AudioObjectAddPropertyListenerBlock(device, &address, .main, listener),
            AudioHardwareError.defaultInputWatchFailed
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

    static func defaultInput() throws -> AudioObjectID {
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
