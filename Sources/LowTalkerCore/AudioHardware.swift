import AVFoundation
import CoreAudio

/// Gives back something the hardware handed out: an engine, a listener. Called once.
public typealias Disposal = @MainActor () -> Void

/// What the system does for capture: run an engine on the default input device, and
/// say when that device changes.
///
/// [LAW:effects-at-boundaries] Both are effects against CoreAudio and AVFoundation.
/// They sit behind this seam so the state machine above them (which engine is live,
/// when to relaunch, what an outage was) runs in tests against hardware a test
/// controls, and on a CI machine that has no microphone at all.
@MainActor
public protocol AudioHardware {
    /// Launches an engine on the current default input device. Every buffer it captures
    /// arrives at `appending` as pipeline samples, on the audio service queue. The
    /// engine reports on the main actor: `onFailure` when a buffer could not be
    /// converted, `onConfigurationChange` when macOS has stopped it because its device
    /// changed. Throws when the current device cannot feed the pipeline, which is what
    /// no device at all looks like.
    func launch(
        appending: @escaping @Sendable ([Float]) -> Void,
        onFailure: @escaping @MainActor (any Error) -> Void,
        onConfigurationChange: @escaping @MainActor () -> Void
    ) throws -> Disposal

    /// Calls `onChange` on the main actor each time the system default input device
    /// changes, until disposed.
    func watchDefaultInput(_ onChange: @escaping @MainActor () -> Void) throws -> Disposal
}

public enum AudioHardwareError: Error, CustomStringConvertible {
    case defaultInputWatchFailed(OSStatus)

    public var description: String {
        switch self {
        case .defaultInputWatchFailed(let status): "CoreAudio refused a listener on the default input device (status \(status))"
        }
    }
}

public struct SystemAudioHardware: AudioHardware {
    public init() {}

    public func launch(
        appending: @escaping @Sendable ([Float]) -> Void,
        onFailure: @escaping @MainActor (any Error) -> Void,
        onConfigurationChange: @escaping @MainActor () -> Void
    ) throws -> Disposal {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        // [LAW:no-shared-mutable-globals] exception: the converter is not Sendable on
        // the macOS 15 SDK, but the tap block is its only caller and the audio service
        // queue serializes the calls, so nothing is shared.
        nonisolated(unsafe) let converter = try AudioClip.Converter(from: source)
        // Explicitly @Sendable: a closure formed here would otherwise inherit main-actor
        // isolation and trap when the tap fires on the audio service queue.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(source.sampleRate / 10), format: source) { @Sendable buffer, _ in
            do {
                appending(try converter.convert(buffer))
            } catch {
                Task { @MainActor in onFailure(error) }
            }
        }
        let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            MainActor.assumeIsolated { onConfigurationChange() }
        }
        let dispose: Disposal = {
            NotificationCenter.default.removeObserver(observer)
            input.removeTap(onBus: 0)
            engine.stop()
        }
        do {
            try engine.start()
        } catch {
            dispose()
            throw error
        }
        return dispose
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
        let status = AudioObjectAddPropertyListenerBlock(system, &adding, .main, listener)
        guard status == noErr else { throw AudioHardwareError.defaultInputWatchFailed(status) }
        return {
            var removing = address
            AudioObjectRemovePropertyListenerBlock(system, &removing, .main, listener)
        }
    }
}
