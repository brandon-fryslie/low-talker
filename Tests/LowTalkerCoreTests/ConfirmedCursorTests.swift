import LowTalkerCore
import Testing

@Suite struct ConfirmedCursorTests {
    /// Each read hands out only the words past the last, so the reads joined are the
    /// transcript, and the transcript that ends the utterance hands out what follows them.
    @Test func eachReadHandsOutOnlyTheWordsPastTheLast() {
        var cursor = ConfirmedCursor()
        #expect(cursor.advance(through: Transcript(typed: "hello").words).text == "hello")
        #expect(cursor.advance(through: Transcript(typed: "hello there").words).text == " there")
        #expect(cursor.advance(through: Transcript(typed: "hello there").words).words.isEmpty)
        #expect(cursor.advance(through: Transcript(typed: "hello there friend").words).text == " friend")
    }

    /// An engine that confirms fewer words than it already had broke `Partial`'s promise; what
    /// it hands out is nothing, not a trap, and nothing it already handed out comes again.
    @Test func fewerConfirmedWordsThanWereHandedOutHandOutNothing() {
        var cursor = ConfirmedCursor()
        _ = cursor.advance(through: Transcript(typed: "one two three").words)
        #expect(cursor.advance(through: Transcript(typed: "one").words).words.isEmpty)
        #expect(cursor.advance(through: Transcript(typed: "one two three four").words).text == " four")
    }
}
