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
/// That last sentence is a claim about a unit bound to a microphone, and it is false of one
/// bound to anything carrying an output - which is what CoreAudio hands an app that enables
/// input too early. `init` is written in the order that avoids it and then reads back
/// whether the device is running, so the split is proven on each preparation rather than
/// believed from this paragraph.
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
    /// Listeners on the bound device, held for as long as this input is - which is as long
    /// as the binding they watch. They were a press's once, and the stretch that left
    /// unwatched is what low-privacy-o1z.aa1 was.
    private let watches: [Disposal]
    /// That this input has stopped being one to open. Held as well as handed to the watches
    /// because the device going away is not the only way that becomes true: a press whose
    /// microphone would not go dark ends on an input nothing should open again either, and
    /// `AudioCapture` answers both the same way - ready another. [LAW:single-enforcer]
    private let onStale: @MainActor () -> Void

    /// Everything a press should not have to pay for: the component, the device binding,
    /// the format, the converter and the buffers, all the way to `AudioUnitInitialize`.
    /// No device is opened here, and macOS lights no indicator for it.
    init(onStale: @escaping @MainActor () -> Void) throws {
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
        // exclusive: the catch here is the one place a preparation gives its unit back, and
        // it cannot double-free one `deinit` is also about to take. Assigning as we went
        // leaked a component per attempt instead - `defaultInput()` below throws on any Mac
        // with no microphone, which is the case `UnreachableInput` exists to carry, and
        // every retry prepared another. [LAW:single-enforcer]
        let device: AudioObjectID
        let sink: Sink
        // Appended one at a time below, and read by the catch, so a second registration that
        // throws still leaves the first one disposable.
        var registered: [Disposal] = []
        do {
            // Output off, then the input device, then input on. The order is load-bearing
            // and nothing here shows it, so it is written down.
            //
            // A HAL unit is born pointing at the default *output* device, which has no
            // input. Enabling input while it points there asks CoreAudio to capture from a
            // device that cannot, and it answers by building this process a private
            // aggregate of the default output and the default input, binding the unit to
            // that, and handing the same aggregate back to anything that asks for the
            // default input afterwards. An aggregate carrying an output runs from
            // `AudioUnitInitialize`, so preparing took the device: LowTalker.app lit the
            // menu-bar indicator at launch and held it for as long as it ran. Bound to the
            // microphone first, the unit never sits in the state that provokes the swap.
            //
            // Only an app meets it - CoreAudio builds that aggregate for clients it offers
            // voice isolation to - so `lowtalker mic indicator` read dark on the very code
            // the app was lighting the menu bar with, and the suite, which never builds the
            // app target, read nothing at all. The check after `AudioUnitInitialize` is
            // what makes the next difference of that shape fail rather than ship.
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

            // Input on bus 1: this unit captures and never plays.
            var enable: UInt32 = 1
            try AudioHardwareError.check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, Self.inputBus, &enable, UInt32(MemoryLayout<UInt32>.size)),
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

            // Which device the unit came out of initialization bound to, which is
            // CoreAudio's answer and not the one we asked for. It has answered differently
            // once already - the aggregate above - and a unit swapped onto one would leave
            // both of the things below pointed at a device the unit no longer uses: the
            // watches listening to it for changes, and the guard asking it whether the
            // preparation took a microphone. [FRAMING:representation]
            device = try Self.boundDevice(unit)

            // This unit is bound to one device, so a device that goes away or changes shape
            // under it is capture's cue to ready another against whatever replaced it. Both
            // watches live here rather than in `open()` because what they watch is the
            // binding, and the binding lasts as long as this input: registered at the press
            // they left the resting stretch between presses unwatched, and a device that
            // renegotiated its format there was heard by nobody. See
            // `AudioHardware.prepareInput` for what that cost. A switch of which device is
            // the *default* leaves both of these quiet and is `AudioCapture`'s to see.
            //
            // Ahead of the guard below, so the claim that a listener costs no device is made
            // the same way every other claim about preparing is: by reading the device back.
            // Registering one should not run a device, and this is the line that would fail
            // the preparation rather than trust it.
            registered.append(try Self.watch(device, kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal, onStale))
            registered.append(try Self.watch(device, kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput, onStale))

            // [LAW:parse-dont-validate] The border between a microphone reached and a
            // microphone taken. Everything above claims to cross it without opening a
            // device, and the epic's whole promise rests on that claim, so this is where a
            // `HALInput` becomes one: the type exists only for a unit whose device is not
            // running on this process's account.
            //
            // Read rather than believed because the claim is about CoreAudio, which is free
            // to change its mind between releases, between devices and - as the aggregate
            // above proved - between an app and a command line running the same lines. A
            // preparation that opened the device throws here and the unwind below gives the
            // device back; what the user is left with is a press that says there is no
            // microphone, rather than an indicator lit all day over an app reporting a shut
            // one. [LAW:no-silent-failure]
            guard try !Self.isRunning(device) else { throw AudioHardwareError.preparingOpenedTheDevice(device) }
            sink = built
        } catch {
            registered.forEach { $0() }
            Self.discard(unit)
            throw error
        }

        self.unit = unit
        self.device = device
        self.sink = sink
        self.watches = registered
        self.onStale = onStale
    }

    /// Opens the device. What a press pays.
    func open(
        appending: @escaping @Sendable ([Float], HostTime) -> Void,
        onFailure: @escaping @MainActor (any Error) -> Void
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
            try AudioHardwareError.check(AudioOutputUnitStart(unit), AudioHardwareError.inputUnavailable)
        } catch {
            // The reading is discarded here alone: a start that failed opened no device to
            // give back, and the error on its way out says more about this press than
            // "the microphone is still on" would.
            close()
            throw error
        }
        return { [weak self] in
            guard let self, !self.close() else { return }
            // The press ended and the microphone did not go dark. Nothing here can put it
            // out - the unit that would not stop is the one this input is built on - so the
            // input is given up instead: `AudioCapture` readies another, lets this one go,
            // and the `deinit` that follows uninitializes and disposes the unit, which is
            // what finally takes the device off this process. An indicator lit between
            // presses is the whole of what `shut` exists to prevent, so it costs the input
            // rather than being dropped. [LAW:no-silent-failure]
            //
            // Posted rather than called, and `onStale` rather than `self` is what the post
            // holds so a report cannot keep the input it is about alive. This runs inside
            // `AudioCapture.dispose`, which every transition reaches while holding its
            // `Started` `inout`: a report landing in the middle of one would read a phase
            // that has not been written back yet, and `replaceEngine` reaching this again
            // through the engine it is replacing would have no bottom. Arriving after the
            // transition is what the generation guard in `inputWentStale` is written for.
            // [LAW:no-ambient-temporal-coupling]
            let onStale = self.onStale
            Task { @MainActor in onStale() }
        }
    }

    /// Gives the device back and leaves the input prepared, so the next press opens it at
    /// the prepared price, and answers whether the microphone actually went dark - the fact
    /// the epic promises, and the one only a caller holding a press can act on.
    /// [LAW:single-enforcer] Every way this input stops comes through here, including the
    /// one `deinit` takes and the one an `open()` that failed partway takes.
    ///
    /// Both steps are idempotent - stopping a stopped unit and clearing a cleared target do
    /// nothing - so this needs no flag saying whether the device is open. It had one, and
    /// because it was set only after a successful start, it made this a no-op on exactly the
    /// path that had something to unwind. [LAW:polishing-by-subtraction] An input closed
    /// twice therefore answers the same both times, which is what lets `deinit` stop a unit
    /// a key-up already stopped and read nothing into it.
    ///
    /// What it does not do is drop the device watches. They belong to the input rather than
    /// to the press, and a key-up that took them down is what left an idle microphone
    /// unwatched.
    @discardableResult
    private func close() -> Bool {
        let stopped = AudioOutputUnitStop(unit)
        // After the stop, so a render already in flight still has somewhere to put the
        // audio it holds rather than dropping it on the floor.
        sink.aim(at: nil)
        // [LAW:parse-dont-validate] The border `init`'s guard stands on, walked the other
        // way: that one proves reaching a microphone took no device, this one proves
        // letting go gave it back.
        //
        // The device is read rather than the status trusted because the failure this is
        // named for returns `noErr` - the `AVAudioEngine` this type replaced stopped
        // without complaint and left the device running, which the class doc records as the
        // reason `shut` could not be built on it. A status says whether CoreAudio accepted
        // the call; only the device says whether the microphone is still on.
        //
        // Both halves were read off this Mac for low-privacy-o1z.pr2, where the vocabulary
        // had been guessed rather than measured. Over ten presses the device read dark the
        // instant `AudioOutputUnitStop` returned, for about 6 µs against that call's 5 ms,
        // which is what makes the reading affordable here rather than owed to a later beat.
        // A device destroyed under a running unit answers every teardown call `noErr` and
        // this property `'who?'`: a microphone that has gone away cannot say it went dark,
        // and that is this input's last press either way, so the unreadable arm is an
        // answer to return rather than an error to raise. [LAW:no-silent-failure]
        return stopped == noErr && (try? Self.isRunning(device)) == false
    }

    /// The scope is the caller's because it is the property's, not this function's:
    /// `kAudioObjectPropertyScopeGlobal` is a scope like any other rather than a wildcard,
    /// and a listener whose address names a different scope than the notification is
    /// published on is never called. Registering an input device's stream format globally
    /// succeeds and then hears nothing, which is the quietest way this could be wrong.
    ///
    /// Static, with the device passed in, so nothing a listener holds is an input. CoreAudio
    /// keeps the block until it is removed, which is now for the whole life of the input
    /// rather than the length of a press, and a block that captured `self` would keep that
    /// input alive past the last reference to it - with its unit, and with `deinit` never
    /// reached to give either back.
    private static func watch(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, _ onChange: @escaping @MainActor () -> Void) throws -> Disposal {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { onChange() } }
        try AudioHardwareError.check(
            AudioObjectAddPropertyListenerBlock(device, &address, .main, listener),
            AudioHardwareError.deviceWatchFailed
        )
        return {
            var removing = address
            let status = AudioObjectRemovePropertyListenerBlock(device, &removing, .main, listener)
            // The two statuses tolerated here were read off this Mac for
            // low-privacy-o1z.pr2. A device destroyed under a live listener does not take
            // the listener with it: removing one answers `noErr`, as does removing the same
            // block twice and removing one that was never added. `kAudioHardwareBadObjectError`
            // came from a single place - an id that never named an object - which this
            // cannot reach, passing only the device `boundDevice` read back. It stays
            // tolerated because that reading destroyed an aggregate device rather than
            // pulling a plug, and a physical connector is the one arm of it still unread.
            //
            // A precondition where the stop in `close()` is a report, and the two are one
            // judgment rather than two: what an unremoved listener leaves behind is already
            // guarded, since `inputWentStale` discards by preparation number anything a
            // stale watch says. So a status nobody has seen costs nothing here and is worth
            // hearing about, while a stop that fails costs the user a lit microphone - dear
            // enough to spend the input on, and far too dear to spend the session on.
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

    /// Whether *this process* has `device` running.
    ///
    /// `kAudioDevicePropertyDeviceIsRunning` answers for the asking process alone, where
    /// the `...IsRunningSomewhere` that `MicrophoneIndicator` reads answers for the whole
    /// Mac. Measured on this Mac with a second process holding the microphone: this reads
    /// 0 and the indicator reads 1. That difference is what lets preparing prove it took no
    /// device while a call, a recording or another agent's `mic indicator` is running - a
    /// check on the indicator would refuse to ready a microphone because something else was
    /// using one. [FRAMING:representation] Two properties, two questions, and this is the
    /// one about us.
    private static func isRunning(_ device: AudioObjectID) throws -> Bool {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try AudioHardwareError.check(
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running),
            AudioHardwareError.runningStateUnreadable
        )
        return running != 0
    }

    /// Which device `unit` is bound to, asked of the unit rather than remembered from what
    /// it was told.
    private static func boundDevice(_ unit: AudioUnit) throws -> AudioObjectID {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try AudioHardwareError.check(
            AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size),
            AudioHardwareError.inputUnavailable
        )
        return device
    }

    /// Gives back everything a unit holds, in the order CoreAudio pairs them.
    /// [LAW:single-enforcer] Both ways a unit ends come through here - a `HALInput` being
    /// let go, and a preparation giving up partway - so the two cannot drift apart on how
    /// much of a unit there is to give back. The guard after `AudioUnitInitialize` is why
    /// that matters: it lets a preparation throw holding a fully initialized unit, which
    /// until then only `deinit` ever had.
    ///
    /// Every step is unconditional, because each is a no-op on a unit that never got that
    /// far - measured for low-privacy-o1z.pr2 rather than assumed: on a unit that never
    /// reached `AudioUnitInitialize`, on one prepared and never opened, and on a second
    /// pass over a unit already stopped and already uninitialized, all three calls answer
    /// `noErr`. [LAW:dataflow-not-control-flow]
    ///
    /// [LAW:no-silent-failure] exception: these three statuses are dropped, and unlike the
    /// stop in `close()` there is nothing better to read instead. Both paths here have no
    /// caller to tell - `deinit`, and an `init` already throwing a truer error than a
    /// teardown status - and no harm to report either, because what the epic cares about is
    /// whether the device came back, and `AudioComponentInstanceDispose` takes it back by
    /// existing: the unit that held it is gone. That is also what makes `close()`'s report
    /// worth making and this one not. A prepared input that would not stop keeps the
    /// device across presses; a disposed one cannot keep anything.
    private static func discard(_ unit: AudioUnit) {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    private static let inputBus: UInt32 = 1

    deinit {
        // The unit is stopped before the sink it renders into is let go: a render already
        // under way holds a pointer to it. `close` is idempotent, so a disposal that
        // already ran leaves nothing for this to do.
        //
        // The one place the watches are given back other than the catch in `init`, and the
        // two cannot both run: a throwing initializer reaches `deinit` only once every
        // stored property is assigned, which is the line after that catch can no longer be
        // taken. [LAW:single-enforcer] per path, which is what the unit already relies on.
        MainActor.assumeIsolated {
            close()
            watches.forEach { $0() }
            Self.discard(unit)
        }
    }
}
