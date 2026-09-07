import ArgumentParser
import Foundation
import KeyboardService
import LowTalkerCore
import Typing

/// Clicks the element with this role and title in the app that is in front, on the virtual
/// mouse, through the installed helper.
///
/// This is the hands half of the pair `see` opens, and the one verb an agent aims at a
/// named button. It exists beside `act` rather than inside it because the two answer
/// different questions: `act` performs a list of actions a route already decided, in a
/// Context it is handed, while this aims at whatever macOS has just put on the screen -
/// a driver approval, a login item prompt - which nothing routed and nobody can name in
/// advance. The clicking itself is `Pointer`'s, unchanged and not repeated here, so both
/// paths land through one mechanism - including the refusal to press while macOS has an
/// alert over everything, which `GuardedMouse.down` owns for every caller rather than this
/// command owning it for itself. [LAW:single-enforcer]
///
/// **The virtual mouse and not a CGEvent**, because that is the whole reason this line of
/// work exists: a report from the driver extension is hardware to the OS and reaches
/// security-sensitive UI, and a posted CGEvent does not.
///
/// The app is discovered rather than named. A dialog is clickable only while it is in
/// front, `frame(ofRole:titled:)` already refuses to read any app that is not, and asking
/// the caller to name what macOS already knows would be a second source for it.
/// [LAW:one-source-of-truth]
struct ClickCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "click",
        abstract: "Click the element with this role and title in the app that is in front."
    )

    @Argument(help: "The Accessibility role of the element, e.g. AXButton.")
    var role: String

    @Argument(help: "Its title, exactly as the screen shows it, e.g. Allow.")
    var title: String

    @MainActor
    func run() async throws {
        let front = try TargetApp.frontmost()
        let interrupt = Interrupt.watched()
        let target = TargetApp(bundleID: front, interrupt: interrupt)
        let helper = HelperConnection()
        let pointer = Pointer(
            mouse: GuardedMouse(pointing: helper.mouse, interrupt: interrupt, screen: target),
            cursor: Pointer.screenCursor,
            locate: target.frame(ofRole:titled:)
        )
        let click = try pointer.click(element: AccessibilityRole(rawValue: role), title: title)
        // The app is named in the report because it was discovered, not given: an agent
        // that aimed at a dialog and hit the app behind it has to be able to tell.
        print("clicked \(role) \(title.debugDescription) in \(front.rawValue) at \(click.at) after \(click.reports) motion reports")
    }
}
