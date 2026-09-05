import LowTalkerCore
import Testing

/// Routing is a pure function of a Context and a Transcript, so every case here is a
/// pair of inputs and the actions expected back; nothing is mocked.
@Suite struct RouterTests {
    static let context = Context(
        chord: KeyChord(modifiers: .rightOption),
        press: .hold,
        frontmostApp: BundleID(rawValue: "com.apple.Notes"),
        focusedElementRole: AccessibilityRole(rawValue: "AXTextArea")
    )

    static let slack = BundleID(rawValue: "com.tinyspeck.slackmacgap")

    @Test func dictationInsertsTheTranscriptAtFocus() {
        let actions = Router(routes: [.dictation])
            .actions(for: Transcript(typed: "Hello, world."), in: Self.context)
        #expect(actions == [.insertText(text: "Hello, world.", target: .focus)])
    }

    /// Nothing said, nothing to do: not even an insert of the empty string.
    @Test func emptyTranscriptProducesNoActions() {
        let router = Router(routes: [.dictation])
        #expect(router.actions(for: Transcript(words: []), in: Self.context) == [])
        #expect(router.actions(for: Transcript(typed: "   "), in: Self.context) == [])
    }

    /// Routes are an ordered list; the first that claims the utterance decides.
    @Test func firstMatchingRouteWins() {
        let router = Router(routes: [
            Route(when: .always, then: .insertTranscript(target: .app(bundleID: Self.slack))),
            .dictation,
        ])
        let actions = router.actions(for: Transcript(typed: "hi"), in: Self.context)
        #expect(actions == [.insertText(text: "hi", target: .app(bundleID: Self.slack))])
    }

    @Test func noRoutesProducesNoActions() {
        #expect(Router(routes: []).actions(for: Transcript(typed: "hi"), in: Self.context) == [])
    }

    /// A typed transcript splits into engine-shaped words and reads back verbatim.
    @Test func typedTranscriptSplitsIntoWordsAndReadsBackUnchanged() {
        let transcript = Transcript(typed: "  Hello,  world. ")
        #expect(transcript.words.map(\.text) == ["  Hello,", "  world. "])
        #expect(transcript.text == "  Hello,  world. ")
        #expect(transcript.words.allSatisfy { $0.time == 0...0 && $0.confidence == 1.0 })
        #expect(Transcript(typed: "").words.isEmpty)
    }
}
