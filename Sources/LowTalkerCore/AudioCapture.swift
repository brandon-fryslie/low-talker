import AVFoundation
import Synchronization

/// Microphone capture that runs for the life of the app. Whatever the input device
/// produces is converted to the pipeline format and appended to a ring, so a session
/// is two positions on the ring and key-down costs nothing.
///
/// The engine is disposable and the ring is not. When the input device changes,
/// macOS stops the engine and posts a configuration change, and a tap reinstalled on
/// that engine never delivers another buffer (tried with stop, reset, prepare, and a
/// delay); only a fresh AVAudioEngine on the new device does. So a device change
/// launches a new engine by the same routine as `start()`, and the ring, which lives
/// here rather than in any engine, carries across.
@MainActor
public final class AudioCapture {
    public enum State {
        case stopped
        case running
        /// Capture stopped on its own and stays stopped until `start()`.
        case failed(any Error)
    }

    /// An engine on the current input device, with the observer that replaces it.
    /// [LAW:types-are-the-program] One value, so an observer can never outlive its
    /// engine or watch a stale one.
    private struct Live {
        let engine: AVAudioEngine
        let observer: any NSObjectProtocol

        func dispose() {
            NotificationCenter.default.removeObserver(observer)
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    private enum Phase {
        case stopped
        case running(Live)
        case failed(any Error)
    }

    /// The ring behind a lock, shared between the tap's queue and the main actor.
    private final class SharedRing: Sendable {
        let ring: Mutex<AudioRing>
        init(_ ring: AudioRing) { self.ring = Mutex(ring) }
    }

    private let shared: SharedRing
    private var phase: Phase = .stopped
    /// Input device changes survived since `start()`.
    public private(set) var deviceChanges = 0

    public init(retaining duration: TimeInterval = 60) {
        shared = SharedRing(AudioRing(retaining: duration))
    }

    public var state: State {
        switch phase {
        case .stopped: .stopped
        case .running: .running
        case .failed(let error): .failed(error)
        }
    }

    /// The sample positions the ring still holds; `upperBound` is the position the
    /// next sample from the microphone will take.
    public var retained: Range<Int> { shared.ring.withLock { $0.retained } }

    public func clip(in range: Range<Int>) -> AudioClip { shared.ring.withLock { $0.clip(in: range) } }

    public func start() throws {
        dispose()
        phase = .running(try launch())
        deviceChanges = 0
    }

    public func stop() {
        dispose()
        phase = .stopped
    }

    private func dispose() {
        if case .running(let live) = phase { live.dispose() }
    }

    private func launch() throws -> Live {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        // [LAW:no-shared-mutable-globals] exception: the converter is not Sendable on
        // the macOS 15 SDK, but the tap block is its only caller and the audio service
        // queue serializes the calls, so nothing is shared.
        nonisolated(unsafe) let converter = try AudioClip.Converter(from: source)
        let shared = shared
        // Explicitly @Sendable: a closure formed here would otherwise inherit main-actor
        // isolation and trap when the tap fires on the audio service queue.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(source.sampleRate / 10), format: source) { @Sendable [weak self] buffer, _ in
            do {
                let samples = try converter.convert(buffer)
                shared.ring.withLock { $0.append(samples) }
            } catch {
                Task { @MainActor in self?.fail(error) }
            }
        }
        let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.replaceEngine() }
        }
        let live = Live(engine: engine, observer: observer)
        do {
            try engine.start()
        } catch {
            live.dispose()
            throw error
        }
        return live
    }

    /// The device changed: macOS already stopped the engine, and it never delivers again.
    private func replaceEngine() {
        dispose()
        do {
            phase = .running(try launch())
            deviceChanges += 1
        } catch {
            phase = .failed(error)
        }
    }

    private func fail(_ error: any Error) {
        dispose()
        phase = .failed(error)
    }
}
