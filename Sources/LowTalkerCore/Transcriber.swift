/// Turns an utterance into a Transcript. The engine behind it is a config choice:
/// WhisperKit first, with Parakeet and Apple's SpeechAnalyzer behind the same seam.
///
/// [LAW:no-ambient-temporal-coupling] A Transcriber is ready the moment it exists.
/// Every engine loads its model in its initializer, so there is no unloaded
/// transcriber to call too early and no warm-up step a caller can forget. The app
/// holds "still loading" as its own state until the initializer returns; here, a
/// value in hand is the proof the model is resident.
public protocol Transcriber: Sendable {
    /// Hears an utterance while it is being spoken. `audio` is the utterance's clips
    /// in the order they were captured, ending when the key comes up; the engine
    /// decodes as they arrive and tells `partial` what it has heard so far, so a HUD
    /// can show text before the key is released. The transcript returned once
    /// `audio` ends is the final one: it replaces every partial. `vocabulary` is
    /// what the speaker is expected to say beyond ordinary speech, told to the
    /// engine before it hears anything, so the mode that started the utterance
    /// biases every reading of it.
    ///
    /// [LAW:types-are-the-program] One final and any number of partials: the final
    /// is the return value, so a caller cannot miss it or receive two.
    func transcribe(
        _ audio: some AsyncSequence<AudioClip, Never> & Sendable,
        expecting vocabulary: Vocabulary,
        partial: @escaping @Sendable (Partial) -> Void
    ) async throws -> Transcript
}

extension Transcriber {
    /// A clip heard all at once: an utterance whose whole audio arrives with the
    /// key-up, so there is nothing to hear early and no partial to show.
    ///
    /// [LAW:one-type-per-behavior] Batch decoding is the one-clip utterance, not a
    /// second path through the engine.
    public func transcribe(_ clip: AudioClip, expecting vocabulary: Vocabulary) async throws -> Transcript {
        try await transcribe(AsyncStream { continuation in
            continuation.yield(clip)
            continuation.finish()
        }, expecting: vocabulary) { _ in }
    }
}

/// What the engine has heard of an utterance still being spoken.
///
/// [LAW:types-are-the-program] Two transcripts, not one with a flag per word: the
/// confirmed words are final and will appear verbatim in the transcript the
/// utterance ends with, while the tentative words are the engine's latest reading
/// of everything after them and the next partial may replace them entirely.
public struct Partial: Hashable, Sendable {
    public let confirmed: Transcript
    public let tentative: Transcript

    public init(confirmed: Transcript, tentative: Transcript) {
        self.confirmed = confirmed
        self.tentative = tentative
    }

    /// Everything heard so far, confirmed then tentative, as one line of text.
    public var text: String {
        confirmed.text + tentative.text
    }
}
