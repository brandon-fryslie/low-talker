import Foundation

/// A picture of every display: the reading that works when Accessibility does not.
///
/// Some apps answer a text read with the empty string whether or not they hold text -
/// `ScreenText` is what stops that from reading as a verdict - and for those apps a
/// screenshot is not a fallback for awkward cases, it is the only verification there is.
/// It raises no prompt and needs no Screen Recording grant, which is what makes it usable
/// by an agent working this machine alone, with nobody to answer a dialog for it.
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
    /// checked. Any existing file is removed first for the same reason: left in place, a
    /// picture from a previous run would let a capture that wrote nothing pass as one
    /// that worked, which is the failure this whole check exists to catch.
    public static func capture(to path: URL) throws -> Screenshot {
        // Removed loudly, never with `try?`. A removal that fails quietly leaves the old
        // picture exactly where the check below looks for evidence, so a capture that wrote
        // nothing would pass on a file taken minutes ago - which is the failure this
        // removal exists to prevent, reintroduced by the act of hiding it.
        // [LAW:no-silent-failure]
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
        let capture = Process()
        capture.executableURL = tool
        capture.arguments = ["-x", path.path]
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
            throw ScreenNotCaptured(path: path, status: capture.terminationStatus, complaint: complaint)
        }
        return Screenshot(path: path, bytes: bytes)
    }
}

/// No picture was written. What `screencapture` said is carried along, because its exit
/// status says nothing and its complaint is the only account of why.
public struct ScreenNotCaptured: Error, CustomStringConvertible {
    public let path: URL
    public let status: Int32
    public let complaint: String

    public var description: String {
        "no screenshot was written to \(path.path): screencapture exited \(status)"
            + (complaint.isEmpty ? " and said nothing about why" : " saying \(complaint.debugDescription)")
    }
}
