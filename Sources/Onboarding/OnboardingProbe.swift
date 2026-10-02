import Grants
import InputSource

/// Who is reading the list, which decides what can be read at all.
public enum OnboardingReader: Sendable {
    /// The app itself, which holds its own privacy grants, and so can read every row.
    ///
    /// - Parameter microphone: the app's microphone, as its own process reads it.
    case theApp(microphone: MicrophoneAuthorization)
    /// Any other process - the CLI. It reads what belongs to the Mac and names the rows
    /// that belong to the app, unread.
    case elsewhere
}

/// Reading this Mac for the list.
///
/// [LAW:effects-at-boundaries] Each reading is an effect, separated from the pure mapping
/// that turns it into a `Requirement`, so the steps can be asserted as values on a Mac that
/// is in none of the states worth checking.
public enum OnboardingProbe {
    /// Everything that must hold before low-talker can hear and type, read off this Mac now.
    ///
    /// The list is assembled here and nowhere else. `lowtalker onboard`, the menu-bar app
    /// and its guided setup are views of one list rather than lists that happen to agree,
    /// and a surface that built its own would drift the first time a requirement was added
    /// to only one of them. [LAW:one-source-of-truth]
    ///
    /// Reading never asks: nothing here can put a system dialog on screen, which is what
    /// lets the app read the list at launch and every time its menu opens.
    ///
    /// - Parameter reader: who is asking, which decides the rows only the app can read.
    public static func readiness(reader: OnboardingReader) -> Readiness {
        let rows = Requirement.Row.allCases
        let requirements: [Requirement] = rows.compactMap { row in
            switch (row, reader) {
            case (.microphone, .theApp(let microphone)):
                let withheld: MicrophoneAuthorization.Withheld? = switch microphone {
                case .granted: nil
                case .withheld(let reason): reason
                }
                return .microphone(withheld)
            // macOS keys the grant to the app that holds it, so any other process asking is
            // told about itself: a CLI run from a terminal would report the terminal's. A
            // reading of the wrong app is worse than none, so the row is named, unread.
            // [LAW:no-silent-failure]
            case (.microphone, .elsewhere):
                return nil
            case (.inputMethod, _):
                return .inputMethod(switchedOn: InstalledInputMethod.isSwitchedOn())
            }
        }
        return Readiness(requirements, notReadHere: rows.filter { row in !requirements.contains { $0.row == row } })
    }
}
