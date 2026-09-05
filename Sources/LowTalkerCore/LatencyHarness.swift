/// Times an engine the way the app pays for it: one load, then every fixture
/// decoded as a batch, which is what key-up costs until decoding streams during
/// the hold. Each fixture is decoded once and then `reruns` more times, so a
/// median shrugs off a stray pause while the first decode stays apart: after
/// warm-load at launch, the first dictation of a session pays it.
///
/// [LAW:effects-at-boundaries] The clock ticks here and nowhere below; scoring is
/// `WordErrorRate`, a pure function, and the engine arrives as a closure so this
/// harness times whatever stands behind `Transcriber`.
public enum LatencyHarness {
    public static func measure(
        _ fixtures: [Fixture],
        reruns: Int,
        load: () async throws -> any Transcriber
    ) async throws -> LatencyReport {
        let clock = ContinuousClock()
        let loading = clock.now
        let transcriber = try await load()
        let load = clock.now - loading
        var results: [LatencyReport.FixtureResult] = []
        for fixture in fixtures {
            var keyUp = clock.now
            var transcript = try await transcriber.transcribe(fixture.clip)
            let first = clock.now - keyUp
            var later: [Duration] = []
            for _ in 0..<reruns {
                keyUp = clock.now
                transcript = try await transcriber.transcribe(fixture.clip)
                later.append(clock.now - keyUp)
            }
            results.append(LatencyReport.FixtureResult(
                name: fixture.name,
                audio: fixture.clip.duration,
                firstKeyUpToTranscript: first,
                laterKeyUpToTranscript: later,
                transcript: transcript,
                wordErrorRate: WordErrorRate(reference: fixture.reference, hypothesis: SpokenWords(transcript.text))
            ))
        }
        return LatencyReport(load: load, fixtures: results)
    }
}

public struct LatencyReport: Sendable {
    /// From asking for the engine to holding one with its model resident.
    public let load: Duration
    public let fixtures: [FixtureResult]

    public struct FixtureResult: Sendable {
        public let name: String
        /// Seconds of speech in the clip.
        public let audio: Double
        /// Batch decoding starts at key-up, so each of these is the whole wait for
        /// the words. The first decode is kept apart from the reruns that follow it.
        public let firstKeyUpToTranscript: Duration
        public let laterKeyUpToTranscript: [Duration]
        /// What the engine heard on the last run.
        public let transcript: Transcript
        public let wordErrorRate: WordErrorRate

        public init(name: String, audio: Double, firstKeyUpToTranscript: Duration, laterKeyUpToTranscript: [Duration], transcript: Transcript, wordErrorRate: WordErrorRate) {
            self.name = name
            self.audio = audio
            self.firstKeyUpToTranscript = firstKeyUpToTranscript
            self.laterKeyUpToTranscript = laterKeyUpToTranscript
            self.transcript = transcript
            self.wordErrorRate = wordErrorRate
        }

        /// The lower middle of every run, so an even count still reports a wait that
        /// happened.
        public var medianKeyUpToTranscript: Duration {
            let sorted = ([firstKeyUpToTranscript] + laterKeyUpToTranscript).sorted()
            return sorted[(sorted.count - 1) / 2]
        }
    }
}
