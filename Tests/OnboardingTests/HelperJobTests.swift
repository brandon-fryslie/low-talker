import DriverExtension
import Flavors
import Foundation
import Testing
@testable import Onboarding

/// The LaunchDaemon `lowtalker helper install` writes, and where it finds the helper to run.
@Suite struct HelperJobTests {
    static let helper = URL(fileURLWithPath: "/Applications/LowTalker.app/Contents/MacOS/lowtalker-keyboardd")

    /// The job names the service its flavor's client dials, under the label that makes a
    /// second claimant loud. A job that bootstrapped one name while the client dialled
    /// another would leave a root daemon nobody can reach, which is what 3ti.13 was.
    @Test(arguments: Flavor.allCases)
    func theJobRegistersTheServiceTheClientConnectsTo(flavor: Flavor) throws {
        let plist = HelperJob.plist(for: flavor, helper: Self.helper)
        #expect(plist["Label"] as? String == flavor.launchdLabel)
        #expect(plist["MachServices"] as? [String: Bool] == [flavor.machServiceName: true])
        #expect(HelperJob.plistPath(for: flavor) == "/Library/LaunchDaemons/\(flavor.launchdLabel).plist")
    }

    /// The helper learns which installation it serves from its arguments alone, and runs
    /// the program it was handed rather than one a bundle names relative to itself.
    @Test(arguments: Flavor.allCases)
    func theJobRunsTheHelperItWasHandedAsItsFlavor(flavor: Flavor) throws {
        let plist = HelperJob.plist(for: flavor, helper: Self.helper)
        #expect(plist["ProgramArguments"] as? [String] == [Self.helper.path, "--flavor", flavor.description])
        #expect(plist["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false])
    }

    /// The plist the job is loaded from is one `PropertyListSerialization` can write, so a
    /// path holding XML's reserved characters needs no escaping by hand.
    @Test func theJobSerializesWhateverThePathHolds() throws {
        let odd = URL(fileURLWithPath: "/Applications/Low <&> \"Talker\".app/Contents/MacOS/lowtalker-keyboardd")
        let data = try PropertyListSerialization.data(fromPropertyList: HelperJob.plist(for: .release, helper: odd), format: .xml, options: 0)
        let back = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect((back["ProgramArguments"] as? [String])?.first == odd.path)
    }

    /// The step's command pastes into a shell whatever the path holds.
    @Test func theCommandAStepNamesQuotesThePath() {
        #expect(HelperJob.command("/Applications/Low Talker's.app/Contents/Helpers/lowtalker", "remove", flavor: .release)
            == "sudo '/Applications/Low Talker'\\''s.app/Contents/Helpers/lowtalker' helper remove --flavor release")
    }

    // MARK: - which helper shipped with a CLI

    /// A CLI an app carries loads that app's helper, wherever inside the bundle it sits.
    @Test func aCarriedCLIShipsTheHelperInItsApp() {
        let cli = URL(fileURLWithPath: "/Applications/LowTalker.app/Contents/Helpers/lowtalker")
        #expect(Carrier.keyboardHelper(shippedWith: cli) == Self.helper)
    }

    /// The app finds the same helper from its own executable, so the app and the CLI it
    /// carries agree on which job is theirs.
    @Test func theAppShipsTheSameHelperAsItsCLI() {
        let app = URL(fileURLWithPath: "/Applications/LowTalker.app/Contents/MacOS/LowTalker")
        #expect(Carrier.keyboardHelper(shippedWith: app) == Self.helper)
    }

    /// A build from a checkout puts the two side by side.
    @Test func aBuiltCLIShipsTheHelperBesideIt() {
        let cli = URL(fileURLWithPath: "/Users/someone/low-talker/.build/debug/lowtalker")
        #expect(Carrier.keyboardHelper(shippedWith: cli).path == "/Users/someone/low-talker/.build/debug/lowtalker-keyboardd")
    }

    // MARK: - what launchd said

    /// The fields are the job's own lines: a `stderr path` is not its `path`.
    @Test func aRecordReadsTheJobsOwnFields() throws {
        let printed = Command.Output(status: 0, stdout: OnboardingProbeTests.installedByTheCLI, stderr: "")
        let record = try #require(try HelperJob.Record(printed, label: OnboardingProbeTests.label, service: OnboardingProbeTests.service))
        #expect(record.path == "/Library/LaunchDaemons/ai.promptctl.low-talker.keyboardd.plist")
        #expect(record.program == Self.helper)
        #expect(record.holdsTheService)
        #expect(record.loadedFromLaunchDaemons)
    }
}
