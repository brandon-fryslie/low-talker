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
    @Test func aCaptureThatWroteNoFileFails() {
        let nowhere = URL(fileURLWithPath: "/var/empty/no-such-directory/shot.png")
        #expect(throws: ScreenNotCaptured.self) {
            try Screenshot.capture(to: nowhere)
        }
        #expect(!FileManager.default.fileExists(atPath: nowhere.path))
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
            try Screenshot.capture(to: stale)
        }
    }
}
