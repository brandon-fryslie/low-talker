import ArgumentParser
import DriverExtension
@testable import LowTalkerCommands
import Testing

/// The driver verbs' exit contract, which scripts and onboarding's steps depend on: 0 done,
/// 2 waiting on a person, and every failure said in one voice.
@Suite struct DriverVerbTests {
    @Test func doneExitsZeroAndWaitingExitsTwo() {
        #expect(DriverVerb.exit(for: .done("the driver is gone.")) == ("lowtalker driver: the driver is gone.", 0))
        #expect(DriverVerb.exit(for: .waitingOnAPerson("restart")).code == 2)
    }

    /// Not only refusals: a failure underneath one - a tool that would not start - leaves
    /// through the same door rather than ArgumentParser's generic one.
    @Test func everyFailureLeavesAsExitOne() {
        struct Underneath: Error {}
        for failure: any Error in [DriverInstallRefusal("no"), Underneath()] {
            #expect(throws: ExitCode(1)) { try DriverVerb.refusing { throw failure } }
        }
    }
}
