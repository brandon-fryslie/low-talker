import LowTalkerCore
import Testing

@Suite struct VocabularyTests {
    /// A term keeps the spelling and case it was given, without the whitespace
    /// around it; spelling is what a vocabulary is for.
    @Test func aTermKeepsItsSpelling() throws {
        let term = try Vocabulary.Term("  Kaytlynn Fryslie\n")
        #expect(term.text == "Kaytlynn Fryslie")
        #expect(term.description == "Kaytlynn Fryslie")
    }

    /// A term with no word in it would be a blank entry in a prompt.
    @Test(arguments: ["", "   ", "...", "\"\""])
    func aTermWithNoWordIsRefused(text: String) {
        #expect(throws: VocabularyError.termSaysNothing(text)) {
            try Vocabulary.Term(text)
        }
    }

    @Test func theEmptyVocabularyHasNoTerms() {
        #expect(Vocabulary.empty.terms.isEmpty)
        #expect(Vocabulary.empty == Vocabulary([]))
    }
}
