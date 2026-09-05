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
    /// A clip whose peak reaches this held speech. Three seconds of room noise on an
    /// M2 Max's built-in microphone peaked at 0.0034 (-50 dBFS) and the quietest
    /// speech in the bench fixtures, LibriSpeech read at a murmur, at 0.03 to 0.05
    /// per tenth of a second, so -34 dBFS sits between them. A clip under it is
    /// silence, and an utterance that never reaches it is heard as nothing said.
    static let speechPeak: Float = 0.02
    /// Audio kept past the last clip with speech in it, so a word's soft tail rides
    /// with the word. Silence to the encoder either way, so it costs the pass nothing.
    static let hangover = AudioClip.sampleCount(for: 0.3)

    private var samples: [Float] = []
    /// Samples through the end of the last clip that held speech.
    private var spoken = 0
    private var ended = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func append(_ clip: AudioClip) {
        samples += clip.samples
        spoken = clip.peak >= Self.speechPeak ? samples.count : spoken
        wake()
    }

    /// The key came up: nothing more arrives.
    func end() {
        ended = true
        wake()
    }

    /// Appends every clip of `audio` as it arrives, then ends the utterance.
    func fill(from audio: some AsyncSequence<AudioClip, Never> & Sendable) async {
        for await clip in audio {
            append(clip)
        }
        end()
    }

    /// How much audio the speech so far is worth a pass over.
    private var speechCount: Int {
        spoken + Self.hangover
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
