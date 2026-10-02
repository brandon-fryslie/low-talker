import AVFoundation
import Grants
import Testing
@testable import Onboarding

/// The list itself, as both surfaces get it. `lowtalker onboard` and the menu-bar app
/// are two views of one assembly, and what is checked here is the part neither of them
/// may quietly disagree about: which requirements are in the list, and in what order.
/// [LAW:behavior-not-structure]
@Suite struct ReadinessTests {
    /// Every requirement the CLI can read, named, on any Mac in any state.
    @Test func theCLIReadsEveryRowThatBelongsToTheMac() {
        #expect(Self.asTheCLISeesIt.requirements.map(\.name) == ["Input method"])
    }

    /// The grant macOS keys to the app is named from the CLI, never read: a CLI reading it
    /// would report its terminal's grant as the app's.
    @Test func theCLINamesTheAppsOwnGrantWithoutReadingIt() {
        #expect(Self.asTheCLISeesIt.notReadHere == [.microphone])
        #expect(Self.asTheCLISeesIt.description.contains("Microphone: only the app can read this"))
    }

    /// The app reads every row the CLI reads, plus its own grant, in the one order.
    @Test func theAppReadsItsOwnGrantWhereTheCLICannot() {
        let asTheAppSeesIt = OnboardingProbe.readiness(reader: .theApp(microphone: .withheld(.notDetermined)))
        #expect(asTheAppSeesIt.requirements.map(\.row) == Requirement.Row.allCases)
        #expect(asTheAppSeesIt.notReadHere.isEmpty)
    }

    /// The microphone row reads the authorization the app handed over.
    @Test func theAppsMicrophoneRowReadsWhatItWasGiven() {
        func microphoneRow(_ reason: MicrophoneAuthorization.Withheld) -> Requirement? {
            OnboardingProbe.readiness(reader: .theApp(microphone: .withheld(reason)))
                .requirements.first { $0.row == .microphone }
        }
        #expect(microphoneRow(.notDetermined)?.reads == "not asked yet")
        #expect(microphoneRow(.denied)?.reads == "turned off")
        #expect(microphoneRow(.restricted)?.met == false)
        let granted = OnboardingProbe.readiness(reader: .theApp(microphone: MicrophonePermission(authority: Authorized()).current))
        #expect(granted.requirements.first { $0.row == .microphone }?.met == true)
    }

    static var asTheCLISeesIt: Readiness {
        OnboardingProbe.readiness(reader: .elsewhere)
    }
}

private struct Authorized: MicrophoneAuthority {
    func status() -> AVAuthorizationStatus { .authorized }
    func requestAccess() async -> Bool { true }
}
