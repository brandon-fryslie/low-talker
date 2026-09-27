import Grants
import Flavors
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
        let asTheAppSeesIt = OnboardingProbe.readiness(flavor: .development, reader: .theApp(privacy: .success(Self.nothingGranted)))
        #expect(asTheAppSeesIt.requirements.map(\.row) == Requirement.Row.allCases)
        #expect(asTheAppSeesIt.notReadHere.isEmpty)
    }

    /// The microphone row reads what the app's reading says, whatever this test process's
    /// own grant is.
    @Test func theAppsGrantRowReadsTheReadingItWasGiven() {
        func grantRows(_ privacy: PrivacyReading) -> [Requirement] {
            OnboardingProbe.readiness(flavor: .development, reader: .theApp(privacy: .success(privacy)))
                .requirements.filter(\.row.readOnlyByTheApp)
        }
        #expect(grantRows(PrivacyReading(microphone: .authorized)).map(\.met) == [true])
        #expect(grantRows(Self.nothingGranted).map(\.met) == [false])
    }

    /// A reading that failed leaves the grant unmet and says why, rather than guessing.
    @Test func aFailedReadingLeavesTheGrantUnmetAndSaysWhy() {
        let rows = OnboardingProbe.readiness(flavor: .development, reader: .theApp(privacy: .failure(PrivacyReadingFailure("no reader"))))
            .requirements.filter(\.row.readOnlyByTheApp)
        #expect(rows.map(\.row) == [.microphone])
        #expect(rows.allSatisfy { !$0.met && $0.reads == "could not be read: no reader" })
    }

    static let nothingGranted = PrivacyReading(microphone: .notDetermined)

    static var asTheCLISeesIt: Readiness {
        OnboardingProbe.readiness(flavor: .development, reader: .elsewhere)
    }
}
