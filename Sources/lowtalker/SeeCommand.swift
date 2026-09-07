import ArgumentParser
import Foundation
import LowTalkerCore
import Typing

/// Reports what is on the screen right now: which app is in front, what its focus is and
/// whether that focus will say what it holds, whether macOS has an alert over everything,
/// and a picture.
///
/// This is the eyes half of the pair `click` completes. It posts no reports and presses
/// nothing - an agent can run it against a modal dialog without changing what is on the
/// screen, which is the point of having it separate from the hands. [LAW:decomposition]
///
/// The picture is not an option, because the apps this exists for are the apps where it is
/// the only true answer: VS Code and Slack report their text as the empty string whether
/// or not they hold text, so an Accessibility reading of them is no verdict at all and the
/// screenshot is the whole of what this command knows. Taking it every time also means a
/// `see` before and a `see` after are comparable pictures, which is how an agent proves a
/// dialog it clicked is gone. [LAW:dataflow-not-control-flow]
struct SeeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "see",
        abstract: "Report the frontmost app, its focus, any system alert, and a screenshot."
    )

    @Option(name: .customLong("shot"), help: "Where to write the screenshot. Defaults to a timestamped file under the temporary directory, so a picture taken before a click does not overwrite the one taken after.")
    var shot: String?

    @MainActor
    func run() async throws {
        let front = try TargetApp.frontmost()
        print("frontmost \(front.rawValue)")

        // Asked before the focus is read, so a screen this command cannot see past is the
        // first thing it says rather than a footnote under a reading taken underneath one.
        // Reported rather than raised: every line here stands or falls on its own, and a
        // question this one cannot answer must not cost the caller the picture below,
        // which is the reading that always works. `click` is where an unreadable alert is
        // fatal, because that is where acting on it would be. [LAW:dataflow-not-control-flow]
        do { print("alerts \(try SystemAlerts.showing())") }
        catch { print("alerts unreadable: \(error)") }

        // A dialog that has taken the front often has no focused element at all, and that
        // is a fact about the screen rather than a failure of this command: it reports the
        // reading it got and carries on to the picture, which is the reading that always
        // works. [LAW:no-silent-failure] What went wrong is printed, never swallowed.
        let screen = TargetApp(bundleID: front, interrupt: Interrupt.watched())
        do {
            let focus = try screen.focus()
            print("focus \(focus.role) holds \(focus.text)")
        } catch {
            print("focus unreadable: \(error)")
        }

        let screenshot = try Screenshot.capture(to: Self.destination(shot))
        print("screenshot \(screenshot.path.path) (\(screenshot.bytes) bytes)")
    }

    /// The file the picture goes to: the one named, or a fresh timestamped one.
    private static func destination(_ named: String?) -> URL {
        named.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("lowtalker-see-\(Int(Date().timeIntervalSince1970 * 1000)).png")
    }
}
