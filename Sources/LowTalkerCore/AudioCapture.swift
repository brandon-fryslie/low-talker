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
/// than in any engine, carries across. What it carries across is spliced: no audio is
/// captured between the two engines, so the position the new one resumes at is kept and
/// a session that spans it is told its clip is not whole.
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

    /// The samples and where their positions sit in time. [LAW:no-ambient-temporal-coupling]
    /// One value under one lock: a position read off the timeline and a slice taken
    /// from the ring must not straddle a buffer that arrived between them.
    private struct Stream: Sendable {
        var ring: AudioRing
        var timeline: AudioTimeline
        /// The first position the engine now feeding the ring will write to. Everything
        /// before it came from an engine that has since stopped, with a stretch of
        /// speech missing in between: nothing is captured while no engine is running,
        /// and positions advance only on capture, so the audio on either side of the
        /// break is spliced together with no seam in the samples to find it by.
        var continuousSince = 0
    }

    /// The stream behind a lock, shared between the tap's queue and the main actor.
    private final class Shared: Sendable {
        let stream: Mutex<Stream>
        init(_ stream: Stream) { self.stream = Mutex(stream) }
    }

    private let hardware: any AudioHardware
    private let shared: Shared
    private var phase: Phase = .stopped
    private var generation = 0
    /// Input device changes capture stayed running across since `start()`: the engine was
    /// replaced without ever failing. Not a claim that no audio was lost to them - the
    /// audio on either side of each one is spliced, which is what a session's
    /// `CapturedAudio` says and this count does not.
    public private(set) var deviceChanges = 0
    public private(set) var outages = Outages()

    nonisolated public static let defaultRetention: TimeInterval = 60

    /// `origin` is when the first sample is expected: nothing has been captured yet,
    /// so the timeline starts on that prediction and the first buffer corrects it.
    public init(
        retaining duration: TimeInterval = defaultRetention,
        hardware: any AudioHardware = SystemAudioHardware(),
        startingAt origin: HostTime = .now
    ) {
        self.hardware = hardware
        shared = Shared(Stream(ring: AudioRing(retaining: duration), timeline: AudioTimeline(startingAt: origin)))
    }

    public var state: State {
        switch phase {
        case .stopped: .stopped
        case .started(_, .running): .running
        case .started(_, .failed(let error, _)): .failed(error)
        }
    }

    /// Marks where a session begins: the position the microphone had reached when
    /// `moment` passed, with the pre-roll it will reach back over. Costs one read; the
    /// microphone keeps running.
    ///
    /// [LAW:one-source-of-truth] The moment is the one the event that began the session
    /// was stamped with, not the one this is called at, so a handler that ran late still
    /// marks the ring where the key went down. A moment later than the newest sample -
    /// the key went down between two buffers - marks the newest sample, since a session
    /// cannot begin in audio that has not been captured.
    public func beginSession(at moment: HostTime, preRoll: TimeInterval = AudioSession.defaultPreRoll) -> AudioSession {
        shared.stream.withLock {
            AudioSession(beginningAt: min($0.timeline.position(at: moment), $0.ring.end), preRoll: preRoll)
        }
    }

    /// Marks where `session` ends and yields its audio: the pre-roll, then everything
    /// captured since it began, and whether that is all of it. The end mark, the slice
    /// and what the slice is missing are taken under one lock, so a buffer arriving in
    /// between cannot separate them.
    ///
    /// [LAW:parse-dont-validate] This is the border a press's audio crosses, and it is
    /// the last place either loss can be seen: the ring clamps a range it cannot fill and
    /// hands back a shorter clip, and a break between two engines leaves no mark in the
    /// samples at all. So what crosses is a `CapturedAudio`, which cannot be read as
    /// whole unless it is.
    public func endSession(_ session: AudioSession) -> CapturedAudio {
        shared.stream.withLock { stream in
            let range = session.range(endingAt: stream.ring.end)
            // Where the session's own audio starts among the positions that exist: the
            // pre-roll may reach back before the first sample ever captured, and audio
            // that never existed was not lost.
            let began = range.clamped(to: 0..<stream.ring.end).lowerBound
            let clip = stream.ring.clip(in: range)
            let lost = CapturedAudio.Loss(
                scrolledOff: stream.ring.scrolledOff(from: range),
                interrupted: began < stream.continuousSince
            )
            return lost.map { .partial(clip, lost: $0) } ?? .whole(clip)
        }
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
        // Everything the engine about to launch captures lands from here on, and
        // everything already in the ring came from one that stopped. Marked before the
        // launch rather than after it: the new engine delivers on its own thread, and a
        // buffer that landed before the mark was taken would move the mark past audio
        // the break had already cost, so a session begun after the break would be told
        // it spanned one. [LAW:no-ambient-temporal-coupling]
        shared.stream.withLock { $0.continuousSince = $0.ring.end }
        let dispose = try hardware.launch(
            appending: { samples, time in
                shared.stream.withLock {
                    // The buffer's first sample takes the position the ring is at, and
                    // that is the sample its stamp dates.
                    $0.timeline.mark($0.ring.end, at: time)
                    $0.ring.append(samples)
                }
            },
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
