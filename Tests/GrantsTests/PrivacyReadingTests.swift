import AVFoundation
import IOKit.hid
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
        #expect((try? granted.microphoneAuthorization.grant()) != nil)
        let denied = PrivacyReading(microphone: .denied, inputMonitoring: .undecided, accessibility: false)
        #expect((try? denied.microphoneAuthorization.grant()) == nil)
    }

    /// Held - the measured preflight, true from Accessibility alone - is granted whatever
    /// IOHID says; otherwise IOHID tells a "no" from never asked.
    @Test func inputMonitoringTakesHeldFirstAndIOHIDForTheRest() {
        #expect(InputMonitoringAccess(held: true, kIOHIDAccessTypeUnknown) == .granted)
        #expect(InputMonitoringAccess(held: true, kIOHIDAccessTypeDenied) == .granted)
        #expect(InputMonitoringAccess(held: false, kIOHIDAccessTypeDenied) == .denied)
        #expect(InputMonitoringAccess(held: false, kIOHIDAccessTypeUnknown) == .undecided)
        #expect(InputMonitoringAccess(held: false, kIOHIDAccessTypeGranted) == .granted)
    }

    /// A reader that cannot start, exits non-zero, or prints something else is a failure
    /// that names the reader, never a reading.
    @Test(arguments: ["/nonexistent/lowtalker", "/usr/bin/false", "/bin/echo"])
    func aReaderThatDoesNotAnswerIsAFailure(reader: String) {
        #expect(throws: PrivacyReadingFailure.self) {
            try PrivacyReading.taken(by: reader, checkingAccessibility: false)
        }
    }
}
