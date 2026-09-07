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
        // Every reading is taken and reported whatever the readings before it did, and a
        // failure travels as a value rather than as an early return. The picture is the
        // reading that always works, and the runs where the others cannot answer - a
        // screen mid-transition, an app with no bundle id, a modal dialog - are exactly
        // the runs where it is the only evidence there will be, so nothing above it may
        // cost the caller it. [LAW:dataflow-not-control-flow]
        let front = Self.reading { try TargetApp.frontmost() }
        print("frontmost \(Self.told(front.map(\.rawValue)))")

        // Asked before the focus is read, so a screen this command cannot see past is
        // said before a reading taken underneath one. `click` is where an unreadable
        // alert is fatal, because that is where acting on it would be.
        print("alerts \(Self.told(Self.reading { try SystemAlerts.showing() }.map(\.description)))")

        // Derived from the reading above rather than taken again: with no app named there
        // is no focus to read, and saying so is the honest reading, not a skipped one. The
        // interrupt is a plain one: `see` presses nothing, and `Interrupt.watched` would
        // take SIGINT from a command that never asks whether it was raised.
        let focus = front.flatMap { bundleID in
            Self.reading { try TargetApp(bundleID: bundleID, interrupt: Interrupt()).focus() }
        }
        print("focus \(Self.told(focus.map { "\($0.role) holds \($0.text)" }))")

        let screenshot = try Screenshot.capture(to: Self.destination(shot))
        print("screenshot \(screenshot.path.path) (\(screenshot.bytes) bytes)")
    }

    /// One reading, kept whichever way it went, so the caller can report it and carry on.
    @MainActor
    private static func reading<T>(_ take: @MainActor () throws -> T) -> Result<T, any Error> {
        do { return .success(try take()) } catch { return .failure(error) }
    }

    /// What a reading said, or why there is nothing to say. [LAW:no-silent-failure] The
    /// failure is printed in the reading's own place rather than swallowed.
    private static func told(_ reading: Result<String, any Error>) -> String {
        switch reading {
        case .success(let said): said
        case .failure(let error): "unreadable: \(error)"
        }
    }

    /// The file the picture goes to: the one named, or a fresh timestamped one.
    private static func destination(_ named: String?) -> URL {
        named.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("lowtalker-see-\(Int(Date().timeIntervalSince1970 * 1000)).png")
    }
}
