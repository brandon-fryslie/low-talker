import Foundation

/// A session's audio, and whether it is all of the audio that session covered.
///
/// [LAW:parse-dont-validate] A clip cannot answer this about itself: one missing the
/// first thirty seconds of what was said looks exactly like one of the last thirty, and
/// the text it transcribes to is a plausible sentence either way. The capture is the one
/// place that knows, holding the ring and having watched the engines come and go, so
/// what crosses out of it carries the knowing. The two cases are the point: there is no
/// way to take the audio of a press without being handed what it is missing.
///
/// [LAW:no-silent-failure] What to do about a partial one is each surface's own
/// decision - `Dictation` refuses to type a fragment, `lowtalker record` writes the wav
/// and says what is gone - but neither can make it by accident.
public enum CapturedAudio: Sendable, Equatable {
    /// Every sample the session covered that the microphone ever captured.
    case whole(AudioClip)
    /// Audio the session covered is not in the clip, and `lost` says by which door.
    case partial(AudioClip, lost: Loss)

    /// What a session's clip is missing.
    ///
    /// [LAW:types-are-the-program] A loss of nothing cannot be made, which is what keeps
    /// `partial` from being able to claim one: holding a `Loss` is itself the proof that
    /// something was lost.
    public struct Loss: Sendable, Equatable {
        /// Samples of the session's own audio the ring had already dropped by the time it
        /// ended: the head of the clip, gone for good. The key was held for longer than
        /// the ring retains, so the first of what was said was overwritten by the last.
        public let scrolledOff: Int
        /// Capture restarted while the session was open - the input device changed, or an
        /// engine that failed was replaced - so the audio between the engine that stopped
        /// and the one that took over is missing from the middle of the clip. How much of
        /// it there was is not knowable: ring positions advance only on capture, so a
        /// stretch nothing captured leaves nothing behind to measure.
        public let interrupted: Bool

        public init?(scrolledOff: Int, interrupted: Bool) {
            guard scrolledOff > 0 || interrupted else { return nil }
            self.scrolledOff = scrolledOff
            self.interrupted = interrupted
        }
    }
}

extension CapturedAudio.Loss: CustomStringConvertible {
    /// What is missing, in the words a surface can hand the user: both doors when both
    /// were taken, since a clip can lose its head to the ring and its middle to a swap.
    public var description: String {
        [
            scrolledOff > 0 ? String(format: "missing its first %.1f s", AudioClip.duration(for: scrolledOff)) : nil,
            interrupted ? "spliced where capture restarted" : nil,
        ].compactMap { $0 }.joined(separator: " and ")
    }
}
