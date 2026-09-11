import Foundation

/// A session is two marks on the ring and the moment the key went down: the position
/// where it began, the position where it ends, and the time the speaker addressed it
/// from. Its audio is the slice between the marks plus a pre-roll before the begin mark,
/// so a key pressed a little after speech starts still holds the first word.
///
/// The pre-roll reaches back over audio the microphone was already capturing and never
/// across the moment it opened, which is what `notReachingBefore` fixes. The two are
/// the same position when the microphone opens for the session, so a press that opens
/// its own microphone has no look-back at all - there is nothing behind an engine that
/// has just started. What lies further back on the ring is some earlier press's audio,
/// and splicing that onto the front of this one would put words said a minute ago in
/// front of the ones just spoken. [LAW:no-silent-failure]
///
/// [LAW:effects-at-boundaries] A value with no ring and no clock: it turns two
/// positions into a range, and the capture engine supplies the positions.
public struct AudioSession: Sendable, Equatable {
    public static let defaultPreRoll: TimeInterval = 0.3

    /// The position the next sample would take when the session began.
    public let begin: Int
    /// The moment the key that began the session went down. `begin` is where that moment
    /// landed among the positions; this is the moment itself, kept because the two stop
    /// agreeing the instant the microphone opens later than the key went down, and the
    /// difference is speech. [LAW:one-source-of-truth]
    public let began: HostTime
    /// Samples before `begin` the session reaches back over, once clamped to what the
    /// microphone had been capturing continuously by then.
    public let preRoll: Int

    public init(beginningAt begin: Int, at moment: HostTime, preRoll: TimeInterval = Self.defaultPreRoll, notReachingBefore floor: Int = 0) {
        precondition(preRoll >= 0, "a pre-roll reaches back, not forward")
        self.begin = begin
        self.began = moment
        self.preRoll = min(AudioClip.sampleCount(for: preRoll), max(0, begin - floor))
    }

    /// Samples at the head of the session the microphone was not open for: the stretch
    /// between the key going down and the first sample anything captured.
    ///
    /// Every press has some of this - an engine takes a moment to open, and no engine can
    /// be started in the past - so the number matters rather than its existence, and
    /// `AudioCapture.warmUpAllowance` is what says how much of it is ordinary. It is
    /// measured off `timeline` rather than carried from the opening because only a
    /// captured sample dates one: at the moment the microphone is told to open, when this
    /// session gets its marks, nothing has been captured for the timeline to measure
    /// from. [LAW:no-ambient-temporal-coupling]
    ///
    /// Answers zero for a session that began at or after the first captured sample, which
    /// is audio that was never lost because it was never addressed.
    public func unheard(by timeline: AudioTimeline) -> Int {
        max(0, begin - timeline.position(at: began))
    }

    /// The positions the session covers once it ends at `end`. The pre-roll reaches no
    /// further back than it was told it could, so the range never names a position no
    /// sample ever took; positions the ring has since dropped are still in it, and
    /// `AudioRing` is what says so.
    public func range(endingAt end: Int) -> Range<Int> {
        (begin - preRoll)..<end
    }
}
