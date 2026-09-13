import DriverExtension
import Foundation
import KeyboardService
import Flavors
import Testing
@testable import Onboarding

/// The two readings onboarding takes for itself, against the text and the files the
/// machine actually produces.
@Suite struct OnboardingProbeTests {
    static let service = "com.lowtalker.keyboardd"
    static let label = "com.lowtalker.keyboardd"

    /// What `launchctl print` prints for a job that holds the Mach service. The endpoint
    /// is handed out at load, so a job that has it names it here.
    static let holdingTheService = """
    system/com.lowtalker.keyboardd = {
    \tactive count = 1
    \tstate = running
    \tendpoints = {
    \t\t"com.lowtalker.keyboardd" = {
    \t\t\tport = 0x1847f7
    \t\t\tactive = 1
    \t\t}
    \t}
    }
    """

    /// The same job when launchd gave the name to somebody else. Measured on this Mac:
    /// the record is complete, the job says `state = running`, and there is simply no
    /// endpoints block. Nothing in it announces the loss.
    ///
    /// Which is the lost-name shape and not a job that has yet to check in - a distinction
    /// worth naming, because a running job that has never checked a service in still names
    /// its endpoint, at `active = 0`. There is no endpoints block here at all.
    static let holdingNothing = """
    system/com.lowtalker.keyboardd = {
    \tactive count = 1
    \tpath = (submitted by smd.338)
    \tstate = running
    \tparent bundle identifier = ltd.deadgrass.low-talker
    \tenvironment = {
    \t\tXPC_SERVICE_NAME => com.lowtalker.keyboardd
    \t}
    }
    """

    @Test func aJobNamingTheEndpointIsHoldingTheService() throws {
        let printed = Command.Output(status: 0, stdout: Self.holdingTheService, stderr: "")
        #expect(try OnboardingProbe.standing(from: printed, label: Self.label, service: Self.service) == .holdingTheService)
    }

    /// The failure this requirement exists for: a job that is loaded, running, and holds
    /// nothing. An app in this state reports its helper enabled and types nothing.
    @Test func aRunningJobWithNoEndpointHasLostTheService() throws {
        let printed = Command.Output(status: 0, stdout: Self.holdingNothing, stderr: "")
        #expect(try OnboardingProbe.standing(from: printed, label: Self.label, service: Self.service) == .anotherJobHoldsTheService)
    }

    /// The whole way from what launchd printed to what the reader is told, on the Mac
    /// where reading it as "is the app's own helper answering" got it wrong: a helper is
    /// up and holding the name, so it has already been through its filing - and a reader
    /// whose answer is still missing needs the log, not a wait for something that already
    /// happened and already failed.
    ///
    /// Taken through the readings rather than by handing the step a bool, because the
    /// bool is what was wrong: every piece here was right on its own while what they
    /// composed to was a reader told to wait forever. [LAW:behavior-not-structure]
    @Test func aHelperHoldingTheNameSendsTheReaderToTheLog() throws {
        let standing = try OnboardingProbe.standing(
            from: Command.Output(status: 0, stdout: Self.holdingTheService, stderr: ""),
            label: Self.label, service: Self.service)
            .sharpenedByTheAppsOwnRegistration(approvalPending: nil)
        #expect(standing == .holdingTheService)

        let step = Requirement.keyboardSetupAssistant(
            answered: false, aHelperHasRun: standing.aHelperHasRun, helperSubsystem: Self.service).step ?? ""
        #expect(step.contains("log show"), "the reader is not told where the failure is reported")
        #expect(!step.contains("clears itself"), "the reader is told to wait for a filing that already happened")
    }

    /// Which standings mean a helper has already had its chance to file the answer. A
    /// holder nobody could identify has not earned the claim, because nothing was read
    /// that says a helper is what took the name - but a job bootstrapped from a plist is
    /// named, is this same helper binary, and was started by launchd, so it reached the
    /// assistant in its first moments exactly as the app's own would have. Saying `false`
    /// there is what sends a Mac running a bootstrapped helper to wait for a filing that
    /// already happened and already failed.
    /// [LAW:no-silent-failure] Exhaustive, so a standing added later has to answer this.
    @Test func onlyAStandingThatNamesARunningHelperSaysOneHasRun() {
        let ran: Set<HelperStanding> = [.holdingTheService, .aBootstrappedJobHoldsTheLabel]
        for standing in HelperStanding.allCases {
            #expect(standing.aHelperHasRun == ran.contains(standing), "\(standing)")
        }
    }

    /// The service name appears in that record as an environment variable, spelled
    /// without the `= {` that an endpoint carries. Reading it as the endpoint would
    /// report every registered job as holding the service, which is the one answer this
    /// probe must never give.
    @Test func theServiceNameInTheEnvironmentIsNotAnEndpoint() throws {
        let printed = Command.Output(status: 0, stdout: Self.holdingNothing, stderr: "")
        #expect(Self.holdingNothing.contains(Self.service))
        #expect(try OnboardingProbe.standing(from: printed, label: Self.label, service: Self.service) != .holdingTheService)
    }

    /// A job launchd has never heard of is a normal answer, and the only non-zero exit
    /// that may become one.
    @Test func aJobLaunchdNeverHeardOfIsNoJob() throws {
        let printed = Command.Output(status: 113, stdout: "", stderr: "Could not find service \"com.lowtalker.keyboardd\" in domain for system")
        #expect(try OnboardingProbe.standing(from: printed, label: Self.label, service: Self.service) == .noJob)
    }

    /// Any other refusal is refused. A launchd nobody could read, reported as "no job",
    /// would send a reader to approve a login item that is already approved.
    /// [LAW:no-silent-failure]
    @Test func alaunchdThatRefusedForAnyOtherReasonIsNotNoJob() {
        let printed = Command.Output(status: 1, stdout: "", stderr: "Operation not permitted")
        #expect(throws: OnboardingUnreadable.self) {
            try OnboardingProbe.standing(from: printed, label: Self.label, service: Self.service)
        }
    }

    // MARK: - the assistant's cache

    /// A Mac that has never met any keyboard has no file, and that is an answer: the
    /// assistant has nothing cached and will ask.
    @Test func noCacheFileMeansTheAssistantWillAsk() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString).plist")
        #expect(try OnboardingProbe.keyboardSetupAssistantAnswered(key: "10203-5824-0", at: missing.path) == false)
    }

    @Test func anEntryForThisKeyboardMeansTheAssistantIsAnswered() throws {
        let path = try Self.writePlist(["keyboardtype": ["10203-5824-0": 40, "1031-4176-0": 40]])
        #expect(try OnboardingProbe.keyboardSetupAssistantAnswered(key: "10203-5824-0", at: path) == true)
    }

    /// A cache full of other devices' answers is not this device's answer. The 3ti.2
    /// spike found an entry from an unrelated country-33 device already sitting here,
    /// and reading it as ours is exactly the mistake that leaves the assistant returning.
    @Test func anotherKeyboardsAnswerIsNotThisKeyboardsAnswer() throws {
        let path = try Self.writePlist(["keyboardtype": ["10203-5824-33": 40, "49291-1133-0": 40]])
        #expect(try OnboardingProbe.keyboardSetupAssistantAnswered(key: "10203-5824-0", at: path) == false)
    }

    /// A file the assistant has not written to yet answers the same as no file.
    @Test func aCacheWithNoKeyboardtypeEntryMeansTheAssistantWillAsk() throws {
        let path = try Self.writePlist(["something else": 1])
        #expect(try OnboardingProbe.keyboardSetupAssistantAnswered(key: "10203-5824-0", at: path) == false)
    }

    /// A file that is there and cannot be read is not an unanswered assistant, and
    /// reporting it as one would have onboarding recommend a root write nobody needed.
    /// [LAW:no-silent-failure]
    @Test func aCacheFileThatCannotBeReadIsRefused() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).plist")
        try Data("this is not a property list".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        #expect(throws: OnboardingUnreadable.self) {
            try OnboardingProbe.keyboardSetupAssistantAnswered(key: "10203-5824-0", at: path.path)
        }
    }

    static func writePlist(_ contents: [String: Any]) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("keyboardtype-\(UUID().uuidString).plist")
        let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
        try data.write(to: path)
        return path.path
    }
}

/// The list itself, as both surfaces get it. `lowtalker onboard` and the menu-bar app
/// are two views of one assembly, and what is checked here is the part neither of them
/// may quietly disagree about: which requirements are in the list, and in what order.
/// [LAW:behavior-not-structure]
@Suite struct ReadinessTests {
    /// Every requirement, named, on any Mac in any state. A reading that failed keeps its
    /// row and its name, so this holds on a machine with no driver package as surely as
    /// on one that is fully set up - which is what makes it a check on the assembly and
    /// not on the Mac it runs on.
    @Test func theListIsTheSameThreeRequirementsInTheSameOrder() {
        #expect(OnboardingProbe.readiness(flavor: .development, approvalPending: nil).requirements.map(\.name)
            == ["Driver extension", "Keyboard helper", "Keyboard Setup Assistant"])
    }

    /// The app's extra reading changes the helper's row and nothing else. A caller that
    /// cannot ask `SMAppService` passes nil and gets launchd's answer unsharpened, which
    /// is the difference between the CLI and the app and the whole of it.
    @Test func onlyTheHelperCanDifferBetweenTheTwoSurfaces() {
        let asTheCLISeesIt = OnboardingProbe.readiness(flavor: .development, approvalPending: nil).requirements
        let asAnUnapprovedAppSeesIt = OnboardingProbe.readiness(flavor: .development, approvalPending: true).requirements
        #expect(asTheCLISeesIt.filter { $0.name != "Keyboard helper" }
            == asAnUnapprovedAppSeesIt.filter { $0.name != "Keyboard helper" })
    }
}
