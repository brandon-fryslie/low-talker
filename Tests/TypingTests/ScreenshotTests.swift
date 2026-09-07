import Foundation
import Testing
@testable import Typing

@Suite struct ScreenshotTests {
    /// The finding this whole check is built on: `screencapture` exits 0 when it could not
    /// write the file. A capture that trusted the exit status would report success here
    /// and hand back a path with nothing at it, so the written file is what is checked.
    ///
    /// [LAW:behavior-not-structure] Asserted as the contract - a capture that wrote no
    /// file fails - rather than by reaching for the exit status this deliberately ignores.
    /// The grant is stated rather than inherited, here and below. Left to the default it
    /// would be read off whatever machine is running the suite, and a headless runner
    /// without Screen Recording refuses before `screencapture` is ever reached - so this
    /// test would pass without exercising the thing it is named for, and say nothing while
    /// doing it. [LAW:verifiable-goals]
    @Test func aCaptureThatWroteNoFileFails() {
        let nowhere = URL(fileURLWithPath: "/var/empty/no-such-directory/shot.png")
        #expect(throws: ScreenNotCaptured.self) {
            try Screenshot.capture(to: nowhere, screenRecordingAllowed: true)
        }
        #expect(!FileManager.default.fileExists(atPath: nowhere.path))
    }

    /// A caller that may not record the screen is refused, and refused before anything on
    /// disk is touched: `screencapture` would write a blank picture that looks exactly like
    /// a real one, and a run that cannot produce evidence must not destroy the evidence
    /// already sitting at the destination either.
    @Test func aCallerThatMayNotRecordTheScreenIsRefusedAndTakesNothingWithIt() throws {
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lowtalker-ungranted-\(UUID().uuidString).png")
        let earlier = Data("a picture from an earlier run".utf8)
        try earlier.write(to: destination)
        defer { try? FileManager.default.removeItem(at: destination) }

        #expect(throws: ScreenNotCaptured.self) {
            try Screenshot.capture(to: destination, screenRecordingAllowed: false)
        }
        #expect(try Data(contentsOf: destination) == earlier)
    }

    /// The recursive-delete hole, closed. `--shot` carries a path from outside, so a
    /// mistyped destination naming a folder must not be cleared to make room for a
    /// picture: `removeItem` would take the folder and everything under it. The file left
    /// inside is what makes this a test of the refusal rather than of the error - a guard
    /// that threw after deleting would satisfy the throw and still have done the damage.
    @Test func aDestinationThatIsADirectoryIsRefusedAndKeepsWhatIsInIt() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lowtalker-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let inside = directory.appendingPathComponent("what-a-mistyped-shot-would-have-taken.txt")
        try Data("still here".utf8).write(to: inside)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: ScreenNotCaptured.self) {
            try Screenshot.capture(to: directory, screenRecordingAllowed: true)
        }
        #expect(try Data(contentsOf: inside) == Data("still here".utf8))
    }

    /// The stale-picture hole, closed. A destination whose directory is not writable can
    /// neither be captured to nor cleared, so a picture left there by an earlier run would
    /// sit exactly where the check looks for evidence and vouch for a capture that wrote
    /// nothing. The removal is therefore loud, and the capture fails rather than passing
    /// on somebody else's file.
    @Test func aStalePictureNeverVouchesForACaptureThatWroteNothing() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lowtalker-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = directory.appendingPathComponent("shot.png")
        try Data("a picture from an earlier run".utf8).write(to: stale)
        // Read and execute, not write: the file cannot be unlinked and nothing new can be
        // written beside it.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        #expect(throws: (any Error).self) {
            try Screenshot.capture(to: stale, screenRecordingAllowed: true)
        }
    }
}
