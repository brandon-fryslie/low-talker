/// The audio of one utterance as it arrives, for an engine that hears it in passes
/// while it is still being spoken. Clips are appended as they are captured; a
/// pass takes the speech so far, and the engine waits here between passes until
/// more has been spoken or the utterance has ended.
///
/// What a pass is handed is the speech: the audio through `hangover` past the last
/// clip that held speech, silence where that much has not arrived yet. Trailing
/// quiet is never worth a pass, during the hold or after it: a pass over the same
/// speech and more silence reads the same words, and the encoder's cost does not
/// shrink with the tail. So the pass in flight when the key comes up is the last
/// one whenever the speaker stopped before releasing, and a hold with nothing said
/// in it costs no decode at all.
///
/// [LAW:no-ambient-temporal-coupling] The wait is on data, not on time: a pass
/// starts when the speech has grown past a sample count, whatever the clock says.
actor Utterance {
    /// The least an utterance's loudest clip can peak at and still be a speaker
    /// rather than a room: 0.01, -40 dBFS. Room noise on an M2 Max's built-in
    /// microphone peaks at -49 to -54 dBFS per tenth of a second, and the bench
    /// fixtures attenuated by 20 dB peak at -33 or louder. Whisper normalizes each
    /// window's log-mel, so it reads audio this soft as it reads loud audio; what
    /// the floor refuses is a hold with nothing in it, which Whisper would read
    /// words into. Level is all a peak knows, so a click this loud is a speaker too.
    static let audible: Float = 0.01
    /// A clip holds speech when its peak stands within this factor of the loudest
    /// clip so far: 16, 24 dB, one speaker's spread from a stressed vowel to a soft
    /// consonant per tenth of a second. A ratio does not move when the level does,
    /// so a soft speaker or a low-gain microphone is cut into the same speech and
    /// quiet as a loud one. On the bench fixtures it names the same last clip of
    /// speech as the absolute -34 dBFS gate it replaces, differing on 18 of some
    /// 800 clip judgements, all mid-utterance.
    static let dynamicRange: Float = 16
    /// Audio kept past the last clip with speech in it, so a word's soft tail rides
    /// with the word. Silence to the encoder either way, so it costs the pass nothing.
    static let hangover = AudioClip.sampleCount(for: 0.3)

    private var samples: [Float] = []
    /// Samples through the end of the last clip that held speech, once one has.
    /// Each clip is judged as it arrives, against the loudest so far, and never
    /// again: a louder clip later may put an earlier one outside the range, but
    /// the speech only ever grows, which is what a pass waiting on it relies on.
    /// [LAW:types-are-the-program] No speech yet is its own state, not a count of
    /// zero: the hangover rides on speech, so with none there is no audio to hand a
    /// pass, and an utterance that ends in this state is refused rather than heard.
    private var spoken: Int?
    /// The loudest clip peak so far: what every clip is judged against, and what an
    /// utterance that never reached the floor is refused with.
    private var loudest: Float = 0
    private var ended = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func append(_ clip: AudioClip) {
        samples += clip.samples
        let peak = clip.peak
        loudest = max(loudest, peak)
        // [LAW:dataflow-not-control-flow] One judgement for every clip, the loudest
        // included: it stands within range of itself, so the clip that lifts the
        // loudest past the floor is the first speech.
        spoken = loudest >= Self.audible && peak * Self.dynamicRange > loudest ? samples.count : spoken
        wake()
    }

    /// The key came up: nothing more arrives.
    func end() {
        ended = true
        wake()
    }

    /// Appends every clip of `audio` as it arrives, then ends the utterance.
    ///
    /// [LAW:parse-dont-validate] An utterance no clip of which reached the floor is
    /// refused here, with its loudest peak: an empty transcript would not say
    /// whether nothing was said or the audio was too soft to be a speaker.
    func fill(from audio: some AsyncSequence<AudioClip, Never> & Sendable) async throws {
        for await clip in audio {
            append(clip)
        }
        end()
        guard spoken != nil else { throw UtteranceError.nothingSpoken(peak: loudest) }
    }

    /// How much audio the speech so far is worth a pass over: none until a clip
    /// has reached the floor.
    private var speechCount: Int {
        spoken.map { $0 + Self.hangover } ?? 0
    }

    /// The speech so far, once it runs to more than `count` samples or the
    /// utterance has ended, whichever comes first.
    func audio(beyond count: Int) async -> (samples: [Float], ended: Bool) {
        while speechCount <= count && !ended {
            await withCheckedContinuation { waiting.append($0) }
        }
        let speech = Array(samples.prefix(speechCount)) + Array(repeating: 0, count: max(0, speechCount - samples.count))
        return (speech, ended)
    }

    private func wake() {
        let woken = waiting
        waiting = []
        for continuation in woken {
            continuation.resume()
        }
    }
}

/// [LAW:no-silent-failure] The one way an utterance yields no transcript: named, with
/// the measurement that decided it, so a quiet file or a silent hold is never an
/// empty answer.
public enum UtteranceError: Error, Equatable, CustomStringConvertible {
    /// No clip reached the audible floor; `peak` is the loudest sample heard.
    case nothingSpoken(peak: Float)

    public var description: String {
        switch self {
        case .nothingSpoken(let peak):
            "nothing spoken: the loudest sample was \(peak), under the audible floor \(Utterance.audible)"
        }
    }
}
