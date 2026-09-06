import Foundation
import Keystrokes
import Testing
@testable import KeyboardLayout

/// The reverse map, read off the layouts this Mac has installed rather than a fixture.
///
/// A fixture would be a second copy of what a layout says, written by the same reading of
/// UCKeyTranslate that the code under test uses, and would agree with it however wrong
/// both were. The installed layouts are the territory. [FRAMING:representation]
@Suite struct KeyboardLayoutTests {
    static let us = try! KeyboardLayout.named("com.apple.keylayout.US")
    static let dvorak = try! KeyboardLayout.named("com.apple.keylayout.Dvorak")

    /// The alphabet the 3ti.2 spike typed, with the usages it typed them as.
    ///
    /// This is the hand-written table that PR #26 drove a real driver with - 500
    /// characters into TextEdit, counted at the event tap and read back off the screen -
    /// so it is the one statement of these usages that was checked against hardware rather
    /// than against another reading of the same API. The reverse map is built by asking
    /// macOS, and nothing in that construction would notice a key code transcribed into
    /// the wrong HID usage; this notices. [LAW:one-source-of-truth]
    static let spikesAlphabet: [(Character, UInt16, Bool)] = {
        func run(from usage: UInt16, _ plain: String, _ shifted: String) -> [(Character, UInt16, Bool)] {
            zip(plain, shifted).enumerated().flatMap { index, pair in
                [(pair.0, usage + UInt16(index), false), (pair.1, usage + UInt16(index), true)]
            }
        }
        let punctuation: [(Character, UInt16, Bool)] = [
            ("\n", 0x28, false), ("\t", 0x2b, false), (" ", 0x2c, false),
            ("-", 0x2d, false), ("_", 0x2d, true), ("=", 0x2e, false), ("+", 0x2e, true),
            ("[", 0x2f, false), ("{", 0x2f, true), ("]", 0x30, false), ("}", 0x30, true),
            ("\\", 0x31, false), ("|", 0x31, true), (";", 0x33, false), (":", 0x33, true),
            ("'", 0x34, false), ("\"", 0x34, true), ("`", 0x35, false), ("~", 0x35, true),
            (",", 0x36, false), ("<", 0x36, true), (".", 0x37, false), (">", 0x37, true),
            ("/", 0x38, false), ("?", 0x38, true),
        ]
        return run(from: 0x04, "abcdefghijklmnopqrstuvwxyz", "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
            + run(from: 0x1e, "1234567890", "!@#$%^&*()")
            + punctuation
    }()

    @Test func theUSLayoutTypesTheSpikesAlphabetWithTheUsagesTheDriverTook() throws {
        for (character, usage, shifted) in Self.spikesAlphabet {
            let typed = try Self.us.keystrokes(for: String(character))
            #expect(typed.count == 1, "\(character.debugDescription) should be one keystroke, not \(typed.count)")
            #expect(typed.first?.usage == Usage(rawValue: usage), "\(character.debugDescription) typed usage \(typed.first?.usage.rawValue ?? 0)")
            #expect(typed.first?.modifiers == (shifted ? .leftShift : []), "\(character.debugDescription) held the wrong modifiers")
        }
    }

    /// Newline is Return, not the carriage return the layout answers with, and tab is Tab.
    @Test func theTwoWhitespaceCharactersThatAreNotSpaceTypeTheirOwnKeys() throws {
        #expect(try Self.us.keystrokes(for: "\n") == [Keystroke(.returnKey)])
        #expect(try Self.us.keystrokes(for: "\t") == [Keystroke(.tab)])
        #expect(try Self.us.keystrokes(for: " ") == [Keystroke(.space)])
    }

    /// The characters this ticket exists for: on a US layout an accented letter is a dead
    /// key and then the letter, which the spike's table had no way to express at all.
    @Test func anAccentedLetterIsADeadKeyAndThenTheLetterItAccents() throws {
        // Option-E leaves an acute accent pending; E under it is the letter it lands on.
        #expect(try Self.us.keystrokes(for: "\u{e9}") == [
            Keystroke(Usage(rawValue: 0x08), .leftOption),
            Keystroke(Usage(rawValue: 0x08)),
        ])
        // Option-N is the tilde, and it lands on a different letter.
        #expect(try Self.us.keystrokes(for: "\u{f1}") == [
            Keystroke(Usage(rawValue: 0x11), .leftOption),
            Keystroke(Usage(rawValue: 0x11)),
        ])
        // Option-U is the umlaut; shift on the second key is what makes it a capital.
        #expect(try Self.us.keystrokes(for: "\u{dc}") == [
            Keystroke(Usage(rawValue: 0x18), .leftOption),
            Keystroke(Usage(rawValue: 0x18), .leftShift),
        ])
    }

    /// The punctuation a transcript actually contains. Whisper writes curly quotes and an
    /// em dash, none of which the spike's printable-ASCII table could type, and each of
    /// which is one key held under Option rather than a dead-key pair.
    @Test func theCurlyQuotesAndDashesWhisperWritesAllType() throws {
        let punctuation = "\u{201c}\u{201d}\u{2018}\u{2019}\u{2014}\u{2013}\u{2026}"
        let typed = try Self.us.keystrokes(for: punctuation)
        #expect(typed.count == punctuation.count, "each of these should be one keystroke")
        #expect(typed.allSatisfy { $0.modifiers.contains(.leftOption) })
        #expect(try Self.us.keystrokes(for: "\u{201c}") == [Keystroke(Usage(rawValue: 0x2f), .leftOption)])
        #expect(try Self.us.keystrokes(for: "\u{2014}") == [Keystroke(Usage(rawValue: 0x2d), [.leftShift, .leftOption])])
    }

    /// Every reference text the bench measures against, typed through the layout. These
    /// are the sentences the app will actually be asked to insert, so a character in one
    /// of them that no key types is this module failing at its whole job.
    @Test func everyBenchFixtureReferenceTypes() throws {
        let bench = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "bench")
        let texts = try FileManager.default
            .subpathsOfDirectory(atPath: bench.path)
            .filter { $0.hasSuffix(".txt") }
            .map { (name: $0, text: try String(contentsOf: bench.appending(path: $0), encoding: .utf8)) }
        // A walk that found nothing would pass every expectation below it. [LAW:no-silent-failure]
        #expect(texts.count >= 10, "the bench should have more reference texts than this")
        for (name, text) in texts {
            #expect(throws: Never.self, "\(name) has a character the US layout cannot type") {
                try Self.us.keystrokes(for: text)
            }
        }
    }

    /// Swift reads a grapheme cluster as one character where macOS types several keys, and
    /// the two disagreements that reach real text are these. Both are refusals of something
    /// plainly typeable, which is the worst kind: the layout can type it and says it cannot.
    @Test func theTextSwiftCountsDifferentlyFromTheKeysStillTypes() throws {
        // A decomposed accented letter is one Character to Swift and was never a key to
        // this map, which is filled with what the keys type - the composed form.
        #expect(try Self.us.keystrokes(for: "e\u{301}") == Self.us.keystrokes(for: "\u{e9}"))
        #expect(Self.us.canType("nai\u{308}ve"))
        // A Windows line break is one Character, so it is one Return and not two keys.
        #expect(try Self.us.keystrokes(for: "\r\n") == [Keystroke(.returnKey)])
        #expect(throws: Never.self) { try Self.us.keystrokes(for: "line one\r\nline two") }
        #expect(try Self.us.keystrokes(for: "a\r\nb").count == 3)
    }

    /// [LAW:parse-dont-validate] Refused whole, at one boundary, naming every character
    /// that cannot be typed rather than the first - an operator who fixes one and runs
    /// again to be told about the next is being told the truth one character at a time.
    @Test func aCharacterTheLayoutCannotTypeIsRefusedAndNamed() throws {
        #expect(throws: UntypeableCharacters.self) { try Self.us.keystrokes(for: "hello \u{1f600}") }
        do {
            _ = try Self.us.keystrokes(for: "a\u{4f60}b\u{597d}c")
            Issue.record("the US layout claimed it could type Chinese")
        } catch let refusal as UntypeableCharacters {
            #expect(refusal.characters == "\u{4f60}\u{597d}")
            #expect("\(refusal)".contains("com.apple.keylayout.US"))
        }
        #expect(Self.us.canType("plain words") == true)
        #expect(Self.us.canType("\u{1f600}") == false)
    }

    /// Dvorak is the check that none of this is the US layout hard-coded behind a reading
    /// of it. The same letters are the same characters and different keys: Dvorak's home
    /// row is a o e u i d h t n s across the keys QWERTY calls A S D F G H J K L semicolon.
    @Test func dvorakTypesTheSameLettersWithDifferentKeys() throws {
        let homeRow: [(Character, UInt16)] = [
            ("a", 0x04), ("o", 0x16), ("e", 0x07), ("u", 0x09), ("i", 0x0a),
            ("d", 0x0b), ("h", 0x0d), ("t", 0x0e), ("n", 0x0f), ("s", 0x33),
        ]
        for (character, usage) in homeRow {
            #expect(try Self.dvorak.keystrokes(for: String(character)) == [Keystroke(Usage(rawValue: usage))],
                    "Dvorak types \(character) on a different key than this")
        }
        // The same sentence, both layouts, different keys and not by accident: only `a`
        // keeps its place, so the two lowerings must differ.
        let sentence = "the quick brown fox"
        let onDvorak = try Self.dvorak.keystrokes(for: sentence)
        let onUS = try Self.us.keystrokes(for: sentence)
        #expect(onDvorak.count == onUS.count)
        #expect(onDvorak != onUS)
    }

    /// A layout is a value read once, so the machine's own keyboard is never switched to
    /// answer a question about another one.
    @Test func theCurrentLayoutIsWhicheverOneTheMachineIsOn() throws {
        let current = try KeyboardLayout.current()
        #expect(current.name.hasPrefix("com.apple.keylayout."))
        #expect(current.canType("the quick brown fox jumps over the lazy dog"))
    }

    @Test func aLayoutThatIsNotInstalledIsANamedFailure() {
        #expect(throws: NoLayout.noSourceNamed("com.apple.keylayout.NotALayout")) {
            try KeyboardLayout.named("com.apple.keylayout.NotALayout")
        }
    }
}
