import CoreGraphics
import Foundation

/// A picture of the main display: the reading that works when Accessibility does not.
///
/// Some apps answer a text read with the empty string whether or not they hold text -
/// `ScreenText` is what stops that from reading as a verdict - and for those apps a
/// screenshot is not a fallback for awkward cases, it is the only verification there is.
///
/// **The grant is inherited, not absent.** A binary run from a terminal that holds Screen
/// Recording is itself allowed, because TCC attributes the grant to the responsible
/// parent process - measured here, `CGPreflightScreenCaptureAccess()` answers `true` for
/// an unsigned throwaway binary launched from this shell. That is the same attribution
/// that makes `AXIsProcessTrusted()` true for those binaries, and reading it as "no grant
/// is needed" is how a run launched from somewhere else gets a blank picture and calls it
/// evidence. So the grant is checked rather than assumed. [LAW:no-silent-failure]
public struct Screenshot: Equatable, Sendable {
    public let path: URL
    /// The size of the file that was written. A caller holding a `Screenshot` holds a
    /// file that exists and has a picture in it, so nothing downstream re-checks.
    /// [LAW:parse-dont-validate]
    public let bytes: Int

    private static let tool = URL(fileURLWithPath: "/usr/sbin/screencapture")

    /// Captures to `path`, replacing whatever was there, and answers with the file it
    /// wrote.
    ///
    /// [LAW:no-silent-failure] **The exit status is not the check and cannot be:**
    /// `screencapture` exits 0 when it could not write the file at all - measured, on a
    /// path whose directory does not exist, where it complains on stderr and still
    /// reports success. The written file is the only honest evidence, so that is what is
    /// checked.
    ///
    /// `screenRecordingAllowed` is the effect taken as a parameter rather than read in
    /// here, for the reason `ScreenText.init(answer:)` is pure: it lets a test ask what
    /// this does without a window server or a TCC grant of its own.
    /// [LAW:effects-at-boundaries]
    public static func capture(
        to path: URL,
        screenRecordingAllowed: Bool = CGPreflightScreenCaptureAccess()
    ) throws -> Screenshot {
        // Asked first, and before anything on disk is touched: a caller that may not
        // capture gets a named refusal rather than a convincing blank picture, and keeps
        // whatever was already at the destination.
        guard screenRecordingAllowed else { throw ScreenNotCaptured.screenRecordingNotAllowed }
        try clear(path)
        let capture = Process()
        capture.executableURL = tool
        // `-m` is the whole of the multi-display story. Without it `screencapture` writes
        // one file per attached display, numbering all but the first, so on a two-monitor
        // Mac nothing is ever written to `path` itself and the check below fails a capture
        // that in fact succeeded. One display named, one file, one thing to verify.
        capture.arguments = ["-x", "-m", path.path]
        let complaints = Pipe()
        capture.standardError = complaints
        try capture.run()
        // Drained before the wait: a process whose stderr pipe fills blocks in write and
        // never exits, so a wait that came first would be a wait on a full buffer.
        let complaint = String(decoding: complaints.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        capture.waitUntilExit()
        // The absence is the failure, and it is raised by name rather than swallowed:
        // this is the one place the two are the same act.
        guard let bytes = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.size] as? Int, bytes > 0 else {
            throw ScreenNotCaptured.nothingWasWritten(path: path, status: capture.terminationStatus, complaint: complaint)
        }
        return Screenshot(path: path, bytes: bytes)
    }

    /// Empties the destination so that what is found there afterwards can only be this
    /// run's picture.
    ///
    /// A stale file left in place would sit exactly where the check looks for evidence and
    /// vouch for a capture that wrote nothing, so the removal is loud and never `try?`.
    /// A directory is refused rather than removed: `removeItem` deletes one recursively,
    /// and `--shot` carries a path from outside, so a mistyped destination would take a
    /// folder and everything under it with it. [LAW:no-silent-failure]
    private static func clear(_ path: URL) throws {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &directory) else { return }
        guard !directory.boolValue else { throw ScreenNotCaptured.destinationIsADirectory(path) }
        try FileManager.default.removeItem(at: path)
    }
}

/// No picture was written, and which of the ways it can fail this was.
///
/// [LAW:one-type-per-behavior] One error for "there is no screenshot", carrying the reason
/// as a case rather than as three error types a caller would have to catch separately.
public enum ScreenNotCaptured: Error, CustomStringConvertible {
    /// The caller does not hold Screen Recording, so a capture would write a blank picture
    /// that looks exactly like a real one.
    case screenRecordingNotAllowed
    /// The destination names a directory, which this will not delete to make room.
    case destinationIsADirectory(URL)
    /// `screencapture` ran and left nothing at the destination. What it said is carried
    /// along, because its exit status says nothing and its complaint is the only account.
    case nothingWasWritten(path: URL, status: Int32, complaint: String)

    public var description: String {
        switch self {
        case .screenRecordingNotAllowed:
            "this process is not allowed to record the screen, so any picture it took would be blank; grant Screen Recording to the app that launched it"
        case .destinationIsADirectory(let path):
            "\(path.path) is a directory, not a file to overwrite; name the picture itself"
        case .nothingWasWritten(let path, let status, let complaint):
            "no screenshot was written to \(path.path): screencapture exited \(status)"
                + (complaint.isEmpty ? " and said nothing about why" : " saying \(complaint.debugDescription)")
        }
    }
}
