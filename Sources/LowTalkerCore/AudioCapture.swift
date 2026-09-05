import Foundation
import Synchronization

/// Microphone capture that runs for the life of the app. Whatever the input device
/// produces is converted to the pipeline format and appended to a ring, so a session
/// is two positions on the ring and key-down costs nothing.
///
/// The engine is disposable and the ring is not. When the input device changes,
/// macOS stops the engine and posts a configuration change, and a tap reinstalled on
/// that engine never delivers another buffer (tried with stop, reset, prepare, and a
/// delay); only a fresh engine on the new device does. So a device change launches a
/// new engine by the same routine as `start()`, and the ring, which lives here rather
/// than in any engine, carries across.
///
/// When the only input device is unplugged, the replacement cannot launch (there is
/// nothing to convert from) and capture is failed. A failed capture has no engine, so
/// the plug-back-in reaches it another way: the system default input device is
/// watched for the whole started period, and a change while failed launches again.
@MainActor
public final class AudioCapture {
    public enum State {
        case stopped
        case running
        /// Capture stopped on its own. It stays that way until the default input device
        /// changes, when it launches again, or until `stop()`.
        case failed(any Error)
    }

    /// The gaps in capture since `start()`, each ended by a device appearing: how
    /// many, and how long without audio all together.
    public struct Outages: Sendable {
        public var count = 0
        public var total: Duration = .zero
    }

    /// An engine on the input device of its moment. The generation is what this
    /// engine's callbacks carry (the tap's failure, the observer's change), so a
    /// callback from a replaced engine is recognized as stale (a counter, because a
    /// replaced engine's address can be reused).
    private struct Live {
        let dispose: Disposal
        let generation: Int
    }

    private enum Engine {
        case running(Live)
        /// No engine since `since`.
        case failed(any Error, since: ContinuousClock.Instant)
    }

    /// [LAW:types-are-the-program] The default-input watch exists exactly between
    /// `start()` and `stop()`, whatever the engine is doing, so it lives beside the
    /// engine rather than in an optional every reader would have to reconcile.
    private enum Phase {
        case stopped
        case started(watch: Disposal, Engine)
    }

    /// The ring behind a lock, shared between the tap's queue and the main actor.
    private final class SharedRing: Sendable {
        let ring: Mutex<AudioRing>
        init(_ ring: AudioRing) { self.ring = Mutex(ring) }
    }

    private let hardware: any AudioHardware
    private let shared: SharedRing
    private var phase: Phase = .stopped
    private var generation = 0
    /// Input device changes survived without a gap since `start()`.
    public private(set) var deviceChanges = 0
    public private(set) var outages = Outages()

    nonisolated public static let defaultRetention: TimeInterval = 60

    public init(retaining duration: TimeInterval = defaultRetention, hardware: any AudioHardware = SystemAudioHardware()) {
        self.hardware = hardware
        shared = SharedRing(AudioRing(retaining: duration))
    }

    public var state: State {
        switch phase {
        case .stopped: .stopped
        case .started(_, .running): .running
        case .started(_, .failed(let error, _)): .failed(error)
        }
    }

    /// The sample positions the ring still holds; `upperBound` is the position the
    /// next sample from the microphone will take.
    public var retained: Range<Int> { shared.ring.withLock { $0.retained } }

    public func clip(in range: Range<Int>) -> AudioClip { shared.ring.withLock { $0.clip(in: range) } }

    /// Marks where a session begins: the next sample's position, with the pre-roll it
    /// will reach back over. Costs one read; the microphone keeps running.
    public func beginSession(preRoll: TimeInterval = AudioSession.defaultPreRoll) -> AudioSession {
        AudioSession(beginningAt: retained.upperBound, preRoll: preRoll)
    }

    /// Marks where `session` ends and yields its audio: the pre-roll, then everything
    /// captured since it began. The end mark and the slice are taken under one lock,
    /// so a buffer arriving in between cannot separate them.
    public func endSession(_ session: AudioSession) -> AudioClip {
        shared.ring.withLock { $0.clip(in: session.range(endingAt: $0.end)) }
    }

    /// Starts listening. The grant is the proof the user allowed it: without one,
    /// macOS lets the engine run and hands it silence, which nothing downstream could
    /// tell from a quiet room.
    public func start(_ grant: MicrophoneGrant) throws {
        stop()
        deviceChanges = 0
        outages = Outages()
        let watch = try hardware.watchDefaultInput { [weak self] in self?.recover() }
        do {
            phase = .started(watch: watch, .running(try launch()))
        } catch {
            watch()
            throw error
        }
    }

    public func stop() {
        if case .started(let watch, let engine) = phase {
            if case .running(let live) = engine { live.dispose() }
            watch()
        }
        phase = .stopped
    }

    // A non-Sendable @MainActor class is only ever held by main-actor code, so its
    // last release is on the main actor; assumeIsolated traps if that stops holding.
    deinit { MainActor.assumeIsolated { stop() } }

    /// The running engine, only while it is still the one a callback was formed for,
    /// with the watch that outlives it. [LAW:no-ambient-temporal-coupling] An observer
    /// block already queued when `dispose()` removes the observer still runs, and the
    /// tap's failure arrives asynchronously, so both callbacks are resolved here by
    /// generation rather than trusted by arrival.
    private func live(of generation: Int) -> (watch: Disposal, live: Live)? {
        guard case .started(let watch, .running(let live)) = phase, live.generation == generation else { return nil }
        return (watch, live)
    }

    private func launch() throws -> Live {
        let shared = shared
        generation += 1
        let generation = generation
        let dispose = try hardware.launch(
            appending: { samples in shared.ring.withLock { $0.append(samples) } },
            onFailure: { [weak self] error in self?.fail(error, from: generation) },
            onConfigurationChange: { [weak self] in self?.replaceEngine(from: generation) }
        )
        return Live(dispose: dispose, generation: generation)
    }

    /// The device changed: macOS already stopped the engine, and it never delivers again.
    private func replaceEngine(from generation: Int) {
        guard case let (watch, live)? = live(of: generation) else { return }
        live.dispose()
        do {
            phase = .started(watch: watch, .running(try launch()))
            deviceChanges += 1
        } catch {
            phase = .started(watch: watch, .failed(error, since: .now))
        }
    }

    /// The default input device changed. A running engine hears that itself, through
    /// its configuration change; a failed one has no engine to hear with, so this is
    /// how a device that appears reaches it. A launch that fails again (the device
    /// that appeared cannot feed the pipeline either) extends the same outage.
    private func recover() {
        guard case .started(let watch, .failed(_, let since)) = phase else { return }
        do {
            phase = .started(watch: watch, .running(try launch()))
            outages.count += 1
            outages.total += .now - since
        } catch {
            phase = .started(watch: watch, .failed(error, since: since))
        }
    }

    /// A failure from an engine a device change has since replaced is stale: the
    /// engine it came from is gone and the one running is healthy.
    private func fail(_ error: any Error, from generation: Int) {
        guard case let (watch, live)? = live(of: generation) else { return }
        live.dispose()
        phase = .started(watch: watch, .failed(error, since: .now))
    }
}
