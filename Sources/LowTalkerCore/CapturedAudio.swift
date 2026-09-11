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
        /// The microphone was not open for part of the session: it delivered nothing at
        /// all between the marks, it opened long enough after the key went down that the
        /// stretch in between was speech rather than warm-up, or it was gone when the key
        /// came up and never came back. Unknowable in samples for the same reason
        /// `interrupted` is - a stretch nothing captured leaves no positions behind.
        ///
        /// [LAW:types-are-the-program] This is the door a press finds when the engine
        /// took longer to start than the key was held, and it is a door of its own so
        /// that a clip with no samples in it is never read as a quiet room. Those are
        /// different things to be told: one is "say it again, louder", the other is "the
        /// microphone was not listening yet".
        ///
        /// The head is the same door rather than one of its own because it is the same
        /// sentence: the microphone opened after the speaker had started talking to it.
        /// A clip missing its head is the danger a clip missing everything is not - it
        /// transcribes to a fluent sentence with the first word gone, which is why the
        /// number that decides when a warm-up has become a gap is written down at
        /// `AudioCapture.warmUpAllowance` rather than chosen here.
        public let unopened: Bool

        public init?(scrolledOff: Int, interrupted: Bool, unopened: Bool = false) {
            guard scrolledOff > 0 || interrupted || unopened else { return nil }
            self.scrolledOff = scrolledOff
            self.interrupted = interrupted
            self.unopened = unopened
        }
    }
}

extension CapturedAudio.Loss: CustomStringConvertible {
    /// What is missing, in the words a surface can hand the user: every door that was
    /// taken, joined, since one press can lose audio through more than one of them.
    public var description: String {
        [
            scrolledOff > 0 ? String(format: "missing its first %.1f s", AudioClip.duration(for: scrolledOff)) : nil,
            interrupted ? "spliced where capture restarted" : nil,
            unopened ? "cut where the microphone was not open" : nil,
        ].compactMap { $0 }.joined(separator: " and ")
    }
}
