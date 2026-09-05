import Foundation

/// A session is two marks on the ring, not a start and stop of the microphone: the
/// position where it began and the position where it ends. Its audio is the slice
/// between them plus a pre-roll before the begin mark, so a key pressed a little
/// after speech starts still holds the first word.
///
/// [LAW:effects-at-boundaries] A value with no ring and no clock: it turns two
/// positions into a range, and the capture engine supplies the positions.
public struct AudioSession: Sendable, Equatable {
    public static let defaultPreRoll: TimeInterval = 0.3

    /// The position the next sample would take when the session began.
    public let begin: Int
    /// Samples before `begin` the session reaches back over.
    public let preRoll: Int

    public init(beginningAt begin: Int, preRoll: TimeInterval = Self.defaultPreRoll) {
        precondition(preRoll >= 0, "a pre-roll reaches back, not forward")
        self.begin = begin
        self.preRoll = AudioClip.sampleCount(for: preRoll)
    }

    /// The positions the session covers once it ends at `end`. The pre-roll may reach
    /// before the first sample ever captured; `AudioRing.clip(in:)` clamps to what exists.
    public func range(endingAt end: Int) -> Range<Int> {
        (begin - preRoll)..<end
    }
}
