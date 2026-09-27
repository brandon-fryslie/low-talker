import AVFoundation
import Testing
@testable import Grants

/// The line `lowtalker grants` prints is the whole contract between the CLI and the app
/// that runs it, so what one prints the other reads back exactly. [LAW:behavior-not-structure]
@Suite struct PrivacyReadingTests {
    @Test(arguments: [
        PrivacyReading(microphone: .authorized),
        PrivacyReading(microphone: .denied),
        PrivacyReading(microphone: .notDetermined),
        PrivacyReading(microphone: .restricted),
    ])
    func whatIsPrintedReadsBackAsTheSameReading(reading: PrivacyReading) throws {
        #expect(try PrivacyReading(line: reading.line) == reading)
    }

    @Test(arguments: ["", "microphone=maybe", "microphone=9", "garbage"])
    func aLineMissingTheGrantIsRefused(line: String) {
        #expect(throws: PrivacyReadingFailure.self) { try PrivacyReading(line: line) }
    }

    /// The microphone grant is minted from the reading, not from this process's own answer.
    @Test func theMicrophoneGrantFollowsTheReading() {
        #expect((try? PrivacyReading(microphone: .authorized).microphoneAuthorization.grant()) != nil)
        #expect((try? PrivacyReading(microphone: .denied).microphoneAuthorization.grant()) == nil)
    }

    /// A reader that cannot start, exits non-zero, or prints something else is a failure
    /// that names the reader, never a reading.
    @Test(arguments: ["/nonexistent/lowtalker", "/usr/bin/false", "/bin/echo"])
    func aReaderThatDoesNotAnswerIsAFailure(reader: String) {
        #expect(throws: PrivacyReadingFailure.self) {
            try PrivacyReading.taken(by: reader)
        }
    }
}
