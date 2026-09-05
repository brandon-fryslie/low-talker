@testable import LowTalkerCore
import Testing

@Suite struct UtteranceTests {
    /// A clip loud enough to be speech.
    static func speech(_ count: Int) -> AudioClip {
        AudioClip(samples: Array(repeating: 0.5, count: count))
    }

    /// A clip too quiet to be speech, but not digital silence.
    static func quiet(_ count: Int) -> AudioClip {
        AudioClip(samples: Array(repeating: 0.001, count: count))
    }

    /// A wait for more than a count returns only once the speech has grown past it,
    /// with everything spoken by then and the hangover after it.
    @Test func audioBeyondACountWaitsForTheSpeechToPassIt() async {
        let utterance = Utterance()
        async let heard = utterance.audio(beyond: 1_600 + Utterance.hangover)
        await utterance.append(Self.speech(1_600))
        await utterance.append(Self.speech(1))
        let (samples, ended) = await heard
        #expect(samples.count == 1_601 + Utterance.hangover)
        #expect(samples.prefix(1_601).allSatisfy { $0 == 0.5 })
        #expect(samples.dropFirst(1_601).allSatisfy { $0 == 0 })
        #expect(!ended)
    }

    /// Quiet after speech is not more speech: the audio is what was spoken plus the
    /// hangover, the hangover carrying the quiet that has actually arrived, and a
    /// wait for more does not return until the utterance ends.
    @Test func quietDoesNotGrowTheSpeech() async {
        let utterance = Utterance()
        await utterance.append(Self.speech(1_600))
        await utterance.append(Self.quiet(16_000))
        let (samples, ended) = await utterance.audio(beyond: 0)
        #expect(samples.count == 1_600 + Utterance.hangover)
        #expect(samples.dropFirst(1_600).allSatisfy { $0 == 0.001 })
        #expect(!ended)
        async let more = utterance.audio(beyond: 1_600 + Utterance.hangover)
        await utterance.append(Self.quiet(16_000))
        await utterance.end()
        let (final, over) = await more
        #expect(final.count == 1_600 + Utterance.hangover)
        #expect(over)
    }

    /// Speech after quiet takes the quiet with it: everything through the last
    /// speech is handed on, however soft the middle was.
    @Test func speechAfterQuietCarriesTheQuiet() async {
        let utterance = Utterance()
        await utterance.append(Self.speech(1_600))
        await utterance.append(Self.quiet(16_000))
        await utterance.append(Self.speech(800))
        let (samples, _) = await utterance.audio(beyond: 0)
        #expect(samples.count == 18_400 + Utterance.hangover)
        #expect(samples[1_600..<17_600].allSatisfy { $0 == 0.001 })
        #expect(samples[17_600..<18_400].allSatisfy { $0 == 0.5 })
    }

    /// The end wakes a wait that the speech never satisfied, with what there is.
    @Test func theEndWakesAWaitWithWhatArrived() async {
        let utterance = Utterance()
        async let heard = utterance.audio(beyond: 100_000)
        await utterance.append(Self.speech(5))
        await utterance.end()
        let (samples, ended) = await heard
        #expect(samples.count == 5 + Utterance.hangover)
        #expect(ended)
    }

    /// A hold with nothing said in it is the hangover of silence and nothing else.
    @Test func nothingSaidIsOnlyTheHangover() async {
        let utterance = Utterance()
        await utterance.append(Self.quiet(32_000))
        await utterance.end()
        let (samples, ended) = await utterance.audio(beyond: 0)
        #expect(samples.count == Utterance.hangover)
        #expect(ended)
    }

    /// Filling from a sequence appends every clip in order and then ends.
    @Test func fillingFromASequenceAppendsEveryClipThenEnds() async {
        let utterance = Utterance()
        let clips = AsyncStream<AudioClip> { continuation in
            continuation.yield(AudioClip(samples: [1, 2]))
            continuation.yield(AudioClip(samples: [3]))
            continuation.finish()
        }
        await utterance.fill(from: clips)
        let (samples, ended) = await utterance.audio(beyond: 0)
        #expect(Array(samples.prefix(3)) == [1, 2, 3])
        #expect(samples.count == 3 + Utterance.hangover)
        #expect(ended)
    }
}
