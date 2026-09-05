import LowTalkerCore
import Testing

@Suite struct AudioSessionTests {
    /// A known signal, a session marked after some of it has played, and a slice that
    /// reaches back over the pre-roll: the samples before the mark are in the clip.
    @Test func sliceReachesBackOverThePreRoll() {
        var ring = AudioRing(capacity: 100)
        ring.append((0..<10).map(Float.init))
        let session = AudioSession(beginningAt: ring.end, preRoll: 3 / AudioClip.sampleRate)
        ring.append((10..<15).map(Float.init))
        let range = session.range(endingAt: ring.end)
        #expect(range == 7..<15)
        #expect(ring.clip(in: range).samples == [7, 8, 9, 10, 11, 12, 13, 14])
    }

    @Test func preRollIsMeasuredAtThePipelineRate() {
        #expect(AudioSession(beginningAt: 16_000).preRoll == 4_800)
        #expect(AudioSession(beginningAt: 16_000).range(endingAt: 20_000) == 11_200..<20_000)
        #expect(AudioSession(beginningAt: 5, preRoll: 0).range(endingAt: 5).isEmpty)
    }

    /// A pre-roll that reaches before the first sample yields what exists.
    @Test func preRollBeforeTheFirstSampleIsClamped() {
        var ring = AudioRing(capacity: 8)
        ring.append([1, 2])
        let session = AudioSession(beginningAt: ring.end, preRoll: 5 / AudioClip.sampleRate)
        ring.append([3])
        #expect(ring.clip(in: session.range(endingAt: ring.end)).samples == [1, 2, 3])
    }
}

@Suite struct SampleCountTests {
    @Test func roundsToTheNearestSample() {
        #expect(AudioClip.sampleCount(for: 1) == 16_000)
        #expect(AudioClip.sampleCount(for: 0.3) == 4_800)
        #expect(AudioClip.sampleCount(for: 3 / AudioClip.sampleRate) == 3)
        #expect(AudioClip.sampleCount(for: 0) == 0)
    }
}
