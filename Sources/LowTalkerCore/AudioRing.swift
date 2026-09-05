/// The most recent `capacity` pipeline samples, addressed by absolute position.
///
/// Positions count every sample ever appended, so a caller can take a position now,
/// keep appending, and slice by that position later: a session is two positions on
/// the ring, not a start and stop of the microphone. Only the newest `capacity`
/// samples are retained; older positions have scrolled off.
///
/// [LAW:effects-at-boundaries] A value with no clock and no thread: the capture
/// engine owns the one that receives the microphone, tests fill one by hand.
public struct AudioRing: Sendable, Equatable {
    public let capacity: Int
    private var storage: [Float]
    /// One past the newest sample: the position the next appended sample will take.
    public private(set) var end = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "a ring must retain at least one sample")
        self.capacity = capacity
        storage = Array(repeating: 0, count: capacity)
    }

    public init(retaining duration: Double) {
        self.init(capacity: AudioClip.sampleCount(for: duration))
    }

    /// The positions still held: at most `capacity` of them, ending at `end`.
    public var retained: Range<Int> { max(0, end - capacity)..<end }

    public mutating func append(_ samples: [Float]) {
        // Only the newest `capacity` samples can survive; the positions of the rest
        // still advance `end`, so a position taken before a long burst stays true.
        let kept = samples.suffix(capacity)
        var position = end + samples.count - kept.count
        for sample in kept {
            storage[position % capacity] = sample
            position += 1
        }
        end += samples.count
    }

    /// The samples at the positions in `range` that are still retained; positions
    /// that scrolled off or are not yet written contribute nothing, so a session
    /// that began before the ring filled, or whose pre-roll reaches before the first
    /// sample, yields what exists rather than failing.
    public func clip(in range: Range<Int>) -> AudioClip {
        let held = range.clamped(to: retained)
        return AudioClip(samples: held.map { storage[$0 % capacity] })
    }
}
