import LowTalkerCore
import Testing

@Suite struct AudioRingTests {
    @Test func retainsTheNewestSamplesAtAbsolutePositions() {
        var ring = AudioRing(capacity: 4)
        ring.append([1, 2, 3])
        ring.append([4, 5, 6])
        #expect(ring.end == 6)
        #expect(ring.retained == 2..<6)
        #expect(ring.clip(in: 2..<6).samples == [3, 4, 5, 6])
    }

    /// A position taken before a burst still names the same sample after it.
    @Test func positionsSurviveWrapping() {
        var ring = AudioRing(capacity: 5)
        ring.append([0, 1, 2])
        let mark = ring.end
        ring.append([3, 4, 5, 6])
        #expect(ring.clip(in: mark..<ring.end).samples == [3, 4, 5, 6])
    }

    @Test func burstLargerThanCapacityKeepsItsTail() {
        var ring = AudioRing(capacity: 3)
        ring.append((1...10).map(Float.init))
        #expect(ring.end == 10)
        #expect(ring.retained == 7..<10)
        #expect(ring.clip(in: 7..<10).samples == [8, 9, 10])
    }

    /// Pre-roll before the first sample and positions that scrolled off both yield
    /// what exists, not an error.
    @Test func clipIsClampedToWhatIsRetained() {
        var ring = AudioRing(capacity: 4)
        ring.append([1, 2])
        #expect(ring.clip(in: -3..<2).samples == [1, 2])
        ring.append([3, 4, 5, 6])
        #expect(ring.clip(in: 0..<6).samples == [3, 4, 5, 6])
        #expect(ring.clip(in: 10..<12).samples.isEmpty)
        #expect(ring.clip(in: 3..<3).samples.isEmpty)
    }

    @Test func capacityFollowsThePipelineRate() {
        #expect(AudioRing(retaining: 1).capacity == Int(AudioClip.sampleRate))
        #expect(AudioRing(retaining: 60).retained.isEmpty)
    }
}
