import Foundation
import Synchronization

/// Times an engine the way the app pays for it: one load, then every fixture held
/// and heard. A hold is simulated in real time: each chunk of the clip reaches the
/// engine when its audio would have been captured, the key comes up with the last
/// chunk, and the clock runs from there until the transcript is back. Delivered
/// as a batch, the whole clip is one chunk that arrives at key-up, so the engine
/// starts from nothing; streamed, it arrives a microphone buffer at a time, so the
/// engine hears during the hold and key-up finalizes the tail. Each fixture is
/// held once and then `reruns` more times, so a median shrugs off a stray pause
/// while the first hold stays apart: after warm-load at launch, the first
/// dictation of a session pays it.
///
/// [LAW:effects-at-boundaries] The clock ticks here and nowhere below; scoring is
/// `WordErrorRate`, a pure function, and the engine arrives as a closure so this
/// harness times whatever stands behind `Transcriber`.
public enum LatencyHarness {
    /// How a hold's audio reaches the engine.
    public enum Delivery: String, CaseIterable, Sendable {
        /// The whole clip, at key-up.
        case batch
        /// A microphone buffer at a time, as the capture engine delivers it.
        case streamed

        /// How much of `clip` arrives at once.
        public func chunk(of clip: AudioClip) -> TimeInterval {
            switch self {
            case .batch: clip.duration
            case .streamed: AudioCapture.bufferDuration
            }
        }
    }

    public static func measure(
        _ fixtures: [Fixture],
        deliveries: [Delivery],
        reruns: UInt,
        load: () async throws -> any Transcriber
    ) async throws -> LatencyReport {
        let clock = ContinuousClock()
        let loading = clock.now
        let transcriber = try await load()
        let load = clock.now - loading
        var results: [LatencyReport.FixtureResult] = []
        for fixture in fixtures {
            for delivery in deliveries {
                let chunks = fixture.clip.chunks(of: delivery.chunk(of: fixture.clip))
                let (first, firstTranscript) = try await hold(chunks, with: transcriber, clock: clock)
                var transcript = firstTranscript
                var later: [LatencyReport.Run] = []
                for _ in 0..<reruns {
                    let run: LatencyReport.Run
                    (run, transcript) = try await hold(chunks, with: transcriber, clock: clock)
                    later.append(run)
                }
                results.append(LatencyReport.FixtureResult(
                    name: fixture.name,
                    delivery: delivery,
                    audio: fixture.clip.duration,
                    first: first,
                    later: later,
                    transcript: transcript,
                    wordErrorRate: WordErrorRate(reference: fixture.reference, hypothesis: SpokenWords(transcript.text))
                ))
            }
        }
        return LatencyReport(load: load, fixtures: results)
    }

    /// One hold: each chunk reaches the engine when its audio would have been
    /// captured, the key comes up with the last, and the transcript is awaited.
    private static func hold(
        _ chunks: [AudioClip],
        with transcriber: any Transcriber,
        clock: ContinuousClock
    ) async throws -> (LatencyReport.Run, Transcript) {
        let (audio, feed) = AsyncStream<AudioClip>.makeStream()
        let firstPartial = Mutex<ContinuousClock.Instant?>(nil)
        let start = clock.now
        async let transcript = transcriber.transcribe(audio) { _ in
            firstPartial.withLock { $0 = $0 ?? clock.now }
        }
        var captured: TimeInterval = 0
        for chunk in chunks {
            captured += chunk.duration
            // [LAW:no-ambient-temporal-coupling] The sleep is the hold: audio exists
            // only once it has been spoken, and this is the one place that says when.
            try await clock.sleep(until: start + .seconds(captured))
            feed.yield(chunk)
        }
        let keyUp = clock.now
        feed.finish()
        let final = try await transcript
        let shown = clock.now
        let firstText = firstPartial.withLock { $0 } ?? shown
        return (LatencyReport.Run(keyUpToTranscript: shown - keyUp, holdToFirstText: firstText - start), final)
    }
}

public struct LatencyReport: Sendable {
    /// From asking for the engine to holding one with its model resident.
    public let load: Duration
    public let fixtures: [FixtureResult]

    public struct Run: Hashable, Sendable {
        /// From the key coming up to the transcript.
        public let keyUpToTranscript: Duration
        /// From the hold beginning to the first text the engine showed: the first
        /// partial, or the transcript when there was none.
        public let holdToFirstText: Duration

        public init(keyUpToTranscript: Duration, holdToFirstText: Duration) {
            self.keyUpToTranscript = keyUpToTranscript
            self.holdToFirstText = holdToFirstText
        }
    }

    public struct FixtureResult: Sendable {
        public let name: String
        public let delivery: LatencyHarness.Delivery
        /// Seconds of speech in the clip.
        public let audio: Double
        /// The first hold is kept apart from the reruns that follow it.
        public let first: Run
        public let later: [Run]
        /// What the engine heard on the last hold.
        public let transcript: Transcript
        public let wordErrorRate: WordErrorRate

        public init(name: String, delivery: LatencyHarness.Delivery, audio: Double, first: Run, later: [Run], transcript: Transcript, wordErrorRate: WordErrorRate) {
            self.name = name
            self.delivery = delivery
            self.audio = audio
            self.first = first
            self.later = later
            self.transcript = transcript
            self.wordErrorRate = wordErrorRate
        }

        public var runs: [Run] { [first] + later }

        /// The lower middle of every hold, so an even count still reports a wait that
        /// happened.
        public var medianKeyUpToTranscript: Duration {
            runs.map(\.keyUpToTranscript).lowerMedian
        }

        public var medianHoldToFirstText: Duration {
            runs.map(\.holdToFirstText).lowerMedian
        }
    }
}

extension Array where Element == Duration {
    /// The lower middle: a value that occurred, for any count from one up.
    var lowerMedian: Duration {
        let sorted = sorted()
        return sorted[(sorted.count - 1) / 2]
    }
}
