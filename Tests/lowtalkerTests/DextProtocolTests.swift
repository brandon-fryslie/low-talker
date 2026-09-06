import Foundation
import Testing
@testable import lowtalker

/// The two byte layouts the dext spike speaks, and the character table it types from.
/// All three are pure and all three fail silently when they are wrong: a byte order
/// guessed the wrong way round still produces a well-formed frame, a transposed pair in
/// the usage table still types a character. Only the daemon and the driver would ever
/// have said so, and only by typing the wrong thing.
@Suite struct DaemonFramingTests {
    /// The header is big-endian, and it is the length of the body alone.
    @Test func theHeaderIsTheBodyLengthBigEndian() throws {
        #expect(try DaemonConnection.bodyLength(header: [0, 0, 1, 0]) == 256)
        #expect(try DaemonConnection.bodyLength(header: [0, 0, 0, 1]) == 1)
        #expect(try DaemonConnection.bodyLength(header: [1, 0, 0, 0]) == 16_777_216)
    }

    /// A frame of nothing at all is refused rather than read as a type byte that is not
    /// there. [LAW:no-silent-failure]
    @Test func anEmptyFrameIsRefused() {
        #expect(throws: DaemonError.self) { try DaemonConnection.bodyLength(header: [0, 0, 0, 0]) }
    }

    /// Every byte of a request frame, written out: the id is eight bytes, big-endian,
    /// most significant first. Reversed, this frame is still well formed and answers to
    /// an id no one is waiting on.
    @Test func aRequestFrameIsLengthThenTypeThenAnEightByteBigEndianID() {
        let bytes = DaemonConnection.frame(.request, id: 0x0102_0304_0506_0708, [0xaa, 0xbb])
        #expect(bytes == [0, 0, 0, 11, 4, 1, 2, 3, 4, 5, 6, 7, 8, 0xaa, 0xbb])
    }

    /// A frame type that carries no id carries no id bytes either, so its payload starts
    /// one byte after the type.
    @Test func aFrameWithoutAnIDCarriesNoIDBytes() {
        #expect(DaemonConnection.frame(.healthCheckResponse, id: nil, []) == [0, 0, 0, 1, 3])
    }

    /// What is written is what is read: the whole point of holding both halves in one
    /// place is that one of them cannot drift from the other. [FRAMING:representation]
    @Test func everyFrameTypeRoundTripsThroughItsOwnParse() throws {
        for type in [DaemonConnection.FrameType.request, .response] {
            let bytes = DaemonConnection.frame(type, id: 0xdead_beef_cafe_0001, [7, 8, 9])
            let (read, id, payload) = try DaemonConnection.parse(body: Array(bytes.dropFirst(4)))
            #expect(read == type)
            #expect(id == 0xdead_beef_cafe_0001)
            #expect(payload == [7, 8, 9])
        }
        for type in [DaemonConnection.FrameType.heartbeat, .userData, .healthCheck, .healthCheckResponse] {
            let bytes = DaemonConnection.frame(type, id: nil, [7, 8, 9])
            let (read, id, payload) = try DaemonConnection.parse(body: Array(bytes.dropFirst(4)))
            #expect(read == type)
            #expect(id == 0)
            #expect(payload == [7, 8, 9])
        }
    }

    /// A request frame too short to hold the id it promises is named, not read past.
    @Test func aRequestFrameTooShortForItsIDIsRefused() {
        #expect(throws: DaemonError.self) { try DaemonConnection.parse(body: [4, 0, 0, 0]) }
    }

    /// A type byte this side was not written for is a refusal, not a default.
    @Test func anUnknownFrameTypeIsRefused() {
        #expect(throws: DaemonError.self) { try DaemonConnection.parse(body: [99]) }
    }

    /// The three parameters are uint64 each, little-endian, in the order vendor,
    /// product, country. The plausible reading - two 16-bit ids and a byte - is 5 bytes
    /// long, well formed, and initializes a keyboard that is not the one asked for.
    @Test func theKeyboardParametersAreThreeLittleEndianUInt64s() {
        #expect(DaemonConnection.keyboardParameters.count == 24)
        #expect(DaemonConnection.keyboardParameters == [
            0xc0, 0x16, 0, 0, 0, 0, 0, 0,
            0xdb, 0x27, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
        ])
    }
}

@Suite struct KeyboardReportTests {
    /// 67 bytes: report id, modifiers, a reserved byte, then 32 usages of two bytes.
    /// The driver reads a fixed-width struct, so a report of any other length is read
    /// as whatever happens to follow it.
    @Test func aReportIsAlwaysSixtySevenBytes() {
        #expect(KeyboardReport(modifiers: 0, keys: []).bytes.count == 67)
        #expect(KeyboardReport(modifiers: 0x02, keys: [0x04]).bytes.count == 67)
        #expect(KeyboardReport(modifiers: 0, keys: Array(repeating: 0x04, count: 32)).bytes.count == 67)
    }

    /// The usages are little-endian, unlike the frame around them, which is big-endian.
    /// The two orders sit within a few lines of each other and neither one announces
    /// itself in the bytes.
    @Test func theUsagesAreLittleEndianAndTheHeaderIsIDModifiersReserved() {
        let bytes = KeyboardReport(modifiers: KeyboardReport.leftShift, keys: [0x0102, 0x04]).bytes
        #expect(Array(bytes.prefix(7)) == [1, 0x02, 0, 0x02, 0x01, 0x04, 0x00])
        #expect(Array(bytes.dropFirst(7)).allSatisfy { $0 == 0 })
    }

    /// The release report holds no keys and no modifiers: it is what ends every press,
    /// and a stray bit in it is a key the driver goes on reporting as held.
    @Test func theReleasedReportHoldsNothingButItsReportID() {
        #expect(KeyboardReport.released.bytes == [1] + Array(repeating: 0, count: 66))
    }
}

@Suite struct USLayoutTests {
    /// The letters run from usage 0x04 in alphabetical order. Written out rather than
    /// derived, because deriving it from the same expression the table uses would prove
    /// only that the expression equals itself.
    @Test func theLettersRunFromUsageFourInOrder() throws {
        let typed = try USLayout.keystrokes(for: "abcdefghijklmnopqrstuvwxyz")
        #expect(typed.map(\.usage) == Array(0x04...0x1d))
        #expect(typed.allSatisfy { !$0.shift })
    }

    /// The digits run from 0x1e and start at one, not zero: 0x27 types "0", which is the
    /// off-by-one this table invites.
    @Test func theDigitsRunFromUsageThirtyWithZeroLast() throws {
        let typed = try USLayout.keystrokes(for: "1234567890")
        #expect(typed.map(\.usage) == Array(0x1e...0x27))
    }

    /// A shifted character types the same key as its unshifted twin, with shift. This is
    /// the check that catches a transposition inside either run, since a slip moves a
    /// character to a usage its twin does not share.
    @Test func everyShiftedCharacterSharesItsTwinsUsage() throws {
        for (plain, shifted) in zip("abcdefghijklmnopqrstuvwxyz1234567890", "ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()") {
            let bare = try USLayout.keystrokes(for: String(plain))[0]
            let held = try USLayout.keystrokes(for: String(shifted))[0]
            #expect(bare.usage == held.usage, "\(plain) and \(shifted) should be one key")
            #expect(!bare.shift)
            #expect(held.shift)
        }
    }

    /// The punctuation pairs, both halves, since these are transcribed from the usage
    /// tables by hand and nothing else in the file checks them.
    @Test func thePunctuationPairsShareTheirKeys() throws {
        for (plain, shifted) in zip("-=[]\\;'`,./", "_+{}|:\"~<>?") {
            let bare = try USLayout.keystrokes(for: String(plain))[0]
            let held = try USLayout.keystrokes(for: String(shifted))[0]
            #expect(bare.usage == held.usage, "\(plain) and \(shifted) should be one key")
            #expect(held.shift)
        }
    }

    /// Two characters that type the same key with the same modifier would mean one of
    /// them never arrives as itself. Nothing in the table's construction prevents it.
    @Test func noTwoCharactersClaimTheSameKeyAndModifier() throws {
        let alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890!@#$%^&*()-=[]\\;'`,./_+{}|:\"~<>? \n\t"
        let typed = try USLayout.keystrokes(for: alphabet)
        #expect(Set(typed.map { "\($0.usage)-\($0.shift)" }).count == alphabet.count)
    }

    /// Whitespace types keys, not nothing: newline is Return, tab is Tab, space is Space.
    @Test func theThreeWhitespaceCharactersTypeTheirOwnKeys() throws {
        #expect(try USLayout.keystrokes(for: "\n")[0].usage == 0x28)
        #expect(try USLayout.keystrokes(for: "\t")[0].usage == 0x2b)
        #expect(try USLayout.keystrokes(for: " ")[0].usage == 0x2c)
    }

    /// [LAW:parse-dont-validate] A character the layout cannot type is refused here and
    /// named, so nothing downstream has to decide what to do with it - and a partly
    /// typeable string is refused whole rather than typed up to the bad character.
    @Test func aCharacterTheLayoutCannotTypeIsRefusedByName() {
        #expect(throws: UntypeableCharacters.self) { try USLayout.keystrokes(for: "café") }
        #expect(throws: UntypeableCharacters.self) { try USLayout.keystrokes(for: "hello 😀") }
        do {
            _ = try USLayout.keystrokes(for: "a€b£c")
            Issue.record("the layout claimed it could type € and £")
        } catch let refusal as UntypeableCharacters {
            #expect(refusal.characters == "€£")
        } catch {
            Issue.record("refused with \(error) rather than naming the characters")
        }
    }

    @Test func typingNothingIsRefused() {
        #expect(throws: (any Error).self) { try USLayout.keystrokes(for: "") }
    }
}
