import Flavors
import Grants
import InputSource

/// Who is reading the list, which decides what can be read at all.
public enum OnboardingReader: Sendable, Hashable {
    /// The app itself, which holds its own privacy grants, and so can read every row.
    ///
    /// - Parameter privacy: the app's grants, read fresh; see `PrivacyReading`.
    case theApp(privacy: Result<PrivacyReading, PrivacyReadingFailure>)
    /// Any other process - the CLI. It reads what belongs to the Mac and names the rows
    /// that belong to the app, unread. See `Requirement.Row.readOnlyByTheApp`.
    case elsewhere

    /// The grants, as far as this reader has them. `canRead` keeps the rows that need them
    /// from any other reader, so the failure here is never shown; it is a failure rather
    /// than a guess so that a row reaching it anyway says so. [LAW:no-silent-failure]
    var privacy: Result<PrivacyReading, PrivacyReadingFailure> {
        switch self {
        case .theApp(let privacy): privacy
        case .elsewhere: .failure(PrivacyReadingFailure("only the app reads its own grants"))
        }
    }

    func canRead(_ row: Requirement.Row) -> Bool {
        switch self {
        case .theApp: true
        case .elsewhere: !row.readOnlyByTheApp
        }
    }
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
    /// - Parameter flavor: which installation is being read. The two run side by side and
    ///   each has its own input method and grants, so every reading below is a reading about
    ///   one of them and there is no such thing as the readiness of "the app".
    /// - Parameter reader: who is asking, which decides the rows only the app can read.
    public static func readiness(flavor: Flavor, reader: OnboardingReader) -> Readiness {
        let rows = Requirement.Row.allCases
        let requirements: [Requirement] = rows.filter(reader.canRead).map { row in
            switch row {
            case .microphone:
                .privacy(.microphone, reader.privacy, flavor: flavor) { reading in
                    let withheld: MicrophoneAuthorization.Withheld? = switch reading.microphoneAuthorization {
                    case .granted: nil
                    case .withheld(let reason): reason
                    }
                    return .microphone(withheld, flavor: flavor)
                }
            case .inputMethod:
                .inputMethod(switchedOn: InputSourceInstaller.isSwitchedOn(flavor), flavor: flavor)
            }
        }
        return Readiness(requirements, notReadHere: rows.filter { !reader.canRead($0) })
    }
}
