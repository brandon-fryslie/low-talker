import AVFoundation
import Testing
@testable import Grants

/// The line `lowtalker grants` prints is the whole contract between the CLI and the app
/// that runs it, so what one prints the other reads back exactly. [LAW:behavior-not-structure]
@Suite struct PrivacyReadingTests {
    @Test(arguments: [
        PrivacyReading(microphone: .authorized, inputMonitoring: .granted, accessibility: true),
        PrivacyReading(microphone: .denied, inputMonitoring: .denied, accessibility: false),
        PrivacyReading(microphone: .notDetermined, inputMonitoring: .undecided, accessibility: false),
        PrivacyReading(microphone: .restricted, inputMonitoring: .granted, accessibility: true),
    ])
    func whatIsPrintedReadsBackAsTheSameReading(reading: PrivacyReading) throws {
        #expect(try PrivacyReading(line: reading.line, accessibility: reading.accessibility) == reading)
    }

    @Test(arguments: ["", "microphone=3", "microphone=3 inputMonitoring=maybe", "microphone=9 inputMonitoring=granted", "garbage"])
    func aLineMissingAGrantIsRefused(line: String) {
        #expect(throws: PrivacyReadingFailure.self) { try PrivacyReading(line: line, accessibility: true) }
    }

    /// The tap needs both of its grants; either one alone is not enough, and an
    /// Accessibility never checked is not held.
    @Test func theTapIsHeldOnlyWithBothOfItsGrants() {
        #expect(PrivacyReading(microphone: .denied, inputMonitoring: .granted, accessibility: true).eventTapHeld)
        #expect(!PrivacyReading(microphone: .authorized, inputMonitoring: .denied, accessibility: true).eventTapHeld)
        #expect(!PrivacyReading(microphone: .authorized, inputMonitoring: .granted, accessibility: false).eventTapHeld)
        #expect(!PrivacyReading(microphone: .authorized, inputMonitoring: .granted, accessibility: nil).eventTapHeld)
    }

    /// The microphone grant is minted from the reading, not from this process's own answer.
    @Test func theMicrophoneGrantFollowsTheReading() {
        let granted = PrivacyReading(microphone: .authorized, inputMonitoring: .undecided, accessibility: false)
        #expect((try? granted.microphonePermission.current.grant()) != nil)
        let denied = PrivacyReading(microphone: .denied, inputMonitoring: .undecided, accessibility: false)
        #expect((try? denied.microphonePermission.current.grant()) == nil)
    }
}
