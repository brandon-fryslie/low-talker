import Foundation
import LowTalkerCore
import Testing

/// The three pipeline types are data first: a Context arrives as JSON from the dry-run
/// CLI, and Actions come back as JSON from Pipe programs. Every test here is about
/// what survives that trip, not how the types are laid out.
@Suite struct PipelineTypesTests {
    static let context = Context(
        chord: KeyChord(modifiers: [.rightOption, .leftShift]),
        press: .hold,
        frontmostApp: BundleID(rawValue: "com.apple.Safari"),
        focusedElementRole: AccessibilityRole(rawValue: "AXTextField")
    )

    static let transcript = Transcript(words: [
        .init(text: "Hello,", time: 0.10...0.42, confidence: 0.98),
        .init(text: " world.", time: 0.50...0.91, confidence: 0.87),
    ])

    /// One of every Action case, so a payload the encoder cannot carry fails here.
    static let actions: [Action] = [
        .insertText(text: "hi", target: .focus),
        .insertText(text: "hi", target: .app(bundleID: BundleID(rawValue: "com.tinyspeck.slackmacgap"))),
        .sendKeys(chord: KeyChord(modifiers: [.leftCommand, .leftShift], key: Key(rawValue: 0x11))),
        .activateApp(bundleID: BundleID(rawValue: "com.apple.Safari")),
        .openURL(url: URL(string: "https://example.com/?q=low%20talker")!),
        .runShortcut(name: "Append to Journal", input: "hi"),
        .runShortcut(name: "Toggle Lights", input: nil),
        .pipe(executable: "/usr/bin/env", arguments: ["rewrite", "--tone", "formal"]),
    ]

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    @Test func contextRoundTripsThroughCodable() throws {
        #expect(try roundTrip(Self.context) == Self.context)
    }

    @Test func transcriptRoundTripsThroughCodable() throws {
        #expect(try roundTrip(Self.transcript) == Self.transcript)
    }

    @Test func everyActionRoundTripsThroughCodable() throws {
        #expect(try roundTrip(Self.actions) == Self.actions)
    }

    /// Text is the words as emitted, whitespace and punctuation included.
    @Test func textIsTheWordsConcatenated() {
        #expect(Self.transcript.text == "Hello, world.")
        #expect(Transcript(words: []).text == "")
    }

    /// The JSON a Pipe program writes by hand. If this shape changes, every Pipe script
    /// in the world breaks, so it is pinned as a literal rather than derived.
    @Test func pipeProgramsWriteReadableJSON() throws {
        let json = """
        [
          {"insertText": {"text": "hi", "target": {"focus": {}}}},
          {"insertText": {"text": "hi", "target": {"app": {"bundleID": "com.tinyspeck.slackmacgap"}}}},
          {"sendKeys": {"chord": {"modifiers": ["leftCommand"], "key": 17}}},
          {"activateApp": {"bundleID": "com.apple.Safari"}},
          {"openURL": {"url": "https://example.com/"}},
          {"runShortcut": {"name": "Toggle Lights"}},
          {"pipe": {"executable": "/usr/bin/env", "arguments": ["rewrite"]}}
        ]
        """
        let decoded = try JSONDecoder().decode([Action].self, from: Data(json.utf8))
        #expect(decoded == [
            .insertText(text: "hi", target: .focus),
            .insertText(text: "hi", target: .app(bundleID: BundleID(rawValue: "com.tinyspeck.slackmacgap"))),
            .sendKeys(chord: KeyChord(modifiers: [.leftCommand], key: Key(rawValue: 17))),
            .activateApp(bundleID: BundleID(rawValue: "com.apple.Safari")),
            .openURL(url: URL(string: "https://example.com/")!),
            .runShortcut(name: "Toggle Lights", input: nil),
            .pipe(executable: "/usr/bin/env", arguments: ["rewrite"]),
        ])
    }

    /// The Context shape the dry-run CLI will accept on `--context`.
    @Test func contextDecodesFromHandWrittenJSON() throws {
        let json = """
        {"chord": {"modifiers": ["rightOption"]}, "press": "tap",
         "frontmostApp": "com.apple.Notes", "focusedElementRole": "AXTextArea"}
        """
        let decoded = try JSONDecoder().decode(Context.self, from: Data(json.utf8))
        #expect(decoded == Context(
            chord: KeyChord(modifiers: [.rightOption]),
            press: .tap,
            frontmostApp: BundleID(rawValue: "com.apple.Notes"),
            focusedElementRole: AccessibilityRole(rawValue: "AXTextArea")
        ))
    }

    /// An end before a start is not a word timing; the decoder refuses it.
    @Test func wordTimingRejectsEndBeforeStart() {
        let json = Data(#"{"text": "x", "time": [1.0, 0.5], "confidence": 1}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Transcript.Word.self, from: json)
        }
    }
}
