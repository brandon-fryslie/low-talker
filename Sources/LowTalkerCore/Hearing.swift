/// The bookkeeping of an utterance decoded in passes while it is still being
/// spoken: which words are settled, what the latest pass read after them, and
/// what the next pass starts from.
///
/// Every pass reads from the cut to the end of the audio so far. It starts a few
/// confirmed words back, the prefix, and is told those words in advance, so the
/// decoder continues a sentence it has heard rather than starting cold at a word
/// boundary; the words it reads for the prefix are dropped. A word settles when
/// two passes in a row read it the same (the local-agreement rule of
/// whisper_streaming, Macháček et al. 2023) and it ended at least `margin` before
/// the later pass's end, so that the next pass, starting no later than that word,
/// still spans more than `margin`. That margin is what keeps every pass decodable:
/// an engine that decodes no window shorter than its end clip would otherwise be
/// handed a span too short to hear and lose the words in it.
///
/// [LAW:effects-at-boundaries] A value with no engine and no clock: words come in
/// with the sample count they were read through, and the engine reads out where
/// to start next and what to say first. The pass itself is the engine's.
struct Hearing: Equatable {
    /// Samples a settled word must end before a pass's end.
    let margin: Int
    /// How many confirmed words a pass starts from.
    let context: Int
    /// Words no later pass will change: every pass since settled them, and they
    /// are only ever read again as a pass's prefix.
    private(set) var confirmed: [Transcript.Word] = []
    /// The latest pass's reading of everything after the confirmed words.
    private(set) var tentative: [Transcript.Word] = []
    /// Samples the latest pass read through.
    private(set) var heard = 0

    init(margin: Int, context: Int) {
        precondition(margin >= 0, "a margin reaches back from a pass's end, not forward")
        precondition(context >= 0, "a pass starts from some confirmed words, or none")
        self.margin = margin
        self.context = context
    }

    /// The confirmed words the next pass starts from and is told in advance.
    var prefix: [Transcript.Word] {
        Array(confirmed.suffix(context))
    }

    /// What the next pass is told to say first: the prefix's text without its final
    /// punctuation. Told a sentence-final period and then hearing a pause, Whisper
    /// closes the transcript there and every word after the pause is lost; told the
    /// words alone, it reads the punctuation back itself and goes on. A prefix word
    /// is matched the same way, so it is dropped whether it comes back punctuated
    /// or not.
    var saying: String {
        Self.unpunctuated(prefix.map(\.text).joined())
    }

    private static func unpunctuated(_ text: String) -> String {
        String(text.reversed().drop(while: \.isPunctuation).reversed())
    }

    /// [LAW:one-source-of-truth] The one rule for two passes reading the same word:
    /// trailing punctuation is the later pass's to revise, in a prefix or in a
    /// tentative word alike.
    private static func sameWord(_ earlier: Transcript.Word, _ later: Transcript.Word) -> Bool {
        unpunctuated(earlier.text) == unpunctuated(later.text)
    }

    /// Where the next pass starts: the first prefix word's start, so the pass hears
    /// the words it is told. [LAW:one-source-of-truth] Derived from the confirmed
    /// words, so it moves forward exactly as they settle and never back.
    var cut: Int {
        prefix.first.map { AudioClip.sampleCount(for: $0.time.lowerBound) } ?? 0
    }

    /// The sample count the audio must exceed before a pass has something to
    /// hear: new audio since the last pass, and more than `margin` past the cut.
    var passable: Int {
        max(heard, cut + margin)
    }

    /// Takes in a pass that read `words`, from the cut through `end` samples. The
    /// words it read for its prefix come first and are dropped; a prefix read
    /// differently stays, visible, rather than vanishing.
    mutating func hear(_ words: [Transcript.Word], through end: Int) {
        let fresh = words.dropFirst(zip(prefix, words).prefix { Self.sameWord($0, $1) }.count)
        let agreed = zip(tentative, fresh).prefix { Self.sameWord($0, $1) }.count
        let settled = fresh.prefix(agreed).prefix { AudioClip.sampleCount(for: $0.time.upperBound) <= end - margin }
        confirmed += settled
        tentative = Array(fresh.dropFirst(settled.count))
        heard = end
    }

    var partial: Partial {
        Partial(confirmed: Transcript(words: confirmed), tentative: Transcript(words: tentative))
    }

    /// The utterance as heard so far, which is the transcript once no more audio
    /// comes: the last pass's reading is final when nothing follows it.
    var transcript: Transcript {
        Transcript(words: confirmed + tentative)
    }
}
