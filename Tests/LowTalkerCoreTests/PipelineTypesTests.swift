import Foundation
import LowTalkerCore
import Testing

/// The pipeline types are data first. Every test here is about what survives decoding and
/// encoding, not how the types are laid out.
@Suite struct PipelineTypesTests {
    static let transcript = Transcript(words: [
        .init(text: "Hello,", time: 0.10...0.42, confidence: 0.98),
        .init(text: " world.", time: 0.50...0.91, confidence: 0.87),
    ])

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    @Test func transcriptRoundTripsThroughCodable() throws {
        #expect(try roundTrip(Self.transcript) == Self.transcript)
    }

    /// Text is the words as emitted, whitespace and punctuation included.
    @Test func textIsTheWordsConcatenated() {
        #expect(Self.transcript.text == "Hello, world.")
        #expect(Transcript(words: []).text == "")
    }

    /// A chord with nothing pressed is not a chord; the decoder refuses it.
    @Test func chordDecodeRejectsNoKeys() {
        let json = Data(#"{"modifiers": []}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(KeyChord.self, from: json)
        }
    }

    /// A probability outside 0...1 is not a confidence, from a number or from JSON.
    @Test func confidenceRejectsValuesOutsideUnitInterval() {
        #expect(Confidence(exactly: 1.5) == nil)
        #expect(Confidence(exactly: -0.1) == nil)
        #expect(Confidence(exactly: 1) == 1.0)
        let json = Data(#"{"text": "x", "time": [0, 1], "confidence": 1.5}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Transcript.Word.self, from: json)
        }
    }

    /// An end before a start is not a word timing; the decoder refuses it.
    @Test func wordTimingRejectsEndBeforeStart() {
        let json = Data(#"{"text": "x", "time": [1.0, 0.5], "confidence": 1}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Transcript.Word.self, from: json)
        }
    }
}
