import DriverExtension
import Flavors
@testable import KeyboardLayout
@testable import KeyboardService
import Keystrokes
import LowTalkerCore
import Onboarding
import Testing
@testable import Typing
@testable import LowTalkerCommands

/// The exit codes `act`, `type` and `keys` share are their contract with a script, and
/// these pin which failure earns which.
@Suite struct PerformExitTests {
    static let unreachable = HelperConnection.Unreachable(reason: "the helper could not be reached: Couldn't communicate with a helper application. (NSCocoaErrorDomain 4099)")
    /// The shape the executor throws when the helper is gone: the route stopped because the
    /// typing stopped because the wire did.
    static let stoppedOnTheWire = RouteStopped(performed: [], cause: TypingStopped(typed: 0, of: 5, cause: unreachable, unreleased: unreachable))

    private struct NotReadAgain: Error {}

    private static func machine(driver: DriverState, helper: HelperStanding) -> Machine {
        Machine(driver: { driver }, helper: { helper })
    }

    /// A machine the classification must not read.
    private static var unreadable: Machine { Machine(driver: { throw NotReadAgain() }, helper: { throw NotReadAgain() }) }

    @Test func textOrAChordThatCannotBeTypedIsThree() {
        let refusals: [any Error] = [
            UntypeableCharacters(characters: "\u{1F600}", layout: "com.apple.keylayout.US"),
            UnpressableChord(chord: KeyChord(modifiers: .rightOption), because: "it has no key to strike"),
            WouldPressTheHotkey(hotkey: KeyChord(modifiers: .rightOption), keystroke: Keystroke(Usage(rawValue: 0x08), [.rightOption])),
        ]
        for refusal in refusals {
            #expect(PerformExit.classify(refusal, flavor: .development, machine: Self.unreadable, cli: "lowtalker").exit == .untypeable)
        }
    }

    /// The driver outranks the helper: without it no helper can type, so it is the step.
    @Test func anUnreachableHelperOnAMacWithoutTheDriverIsFive() {
        let failure = PerformExit.classify(Self.stoppedOnTheWire, flavor: .development, machine: Self.machine(driver: .awaitingApproval, helper: .noJob), cli: "lowtalker")
        #expect(failure.exit == .driverNotActivated)
        #expect(failure.said.contains("Driver extension: awaiting-approval"))
    }

    /// The driver alone decides it, so a helper that cannot be read does not cost the code.
    @Test func aDriverNotActivatedIsFiveWithoutReadingTheHelper() {
        let machine = Machine(driver: { .awaitingApproval }, helper: { throw NotReadAgain() })
        #expect(PerformExit.classify(Self.stoppedOnTheWire, flavor: .development, machine: machine, cli: "lowtalker").exit == .driverNotActivated)
    }

    /// A click reaches the helper as a keystroke does, so it stops on the same wire.
    @Test func aClickStoppedOnTheWireReadsTheMachineAsTypingDoes() {
        let clicked = RouteStopped(performed: [], cause: PointingStopped(cause: Self.unreachable))
        let failure = PerformExit.classify(clicked, flavor: .development, machine: Self.machine(driver: .awaitingApproval, helper: .noJob), cli: "lowtalker")
        #expect(failure.exit == .driverNotActivated)
    }

    @Test func anUnreachableHelperThatIsNotAnsweringIsFour() {
        for standing in HelperStanding.allCases where standing != .holdingTheService {
            let failure = PerformExit.classify(Self.stoppedOnTheWire, flavor: .release, machine: Self.machine(driver: .enabled, helper: standing), cli: "lowtalker")
            #expect(failure.exit == .helperNotApproved, "\(standing)")
            #expect(failure.said.contains("Keyboard helper: "))
        }
    }

    /// Both rows met and the wire still refused: nothing here can name it, so it is 1 with
    /// the wire's own words - a caller refused by code signing lands here.
    @Test func anUnreachableHelperOnAReadyMacNamesNoCode() {
        let failure = PerformExit.classify(Self.stoppedOnTheWire, flavor: .development, machine: Self.machine(driver: .running, helper: .holdingTheService), cli: "lowtalker")
        #expect(failure.exit == nil)
        #expect(failure.said == "\(Self.stoppedOnTheWire)")
    }

    /// [LAW:no-silent-failure] A reading that decides the code and cannot be taken is not a
    /// guess at a cause - whether it is the driver's or, behind a met driver, the helper's.
    @Test func aDecidingReadingThatCannotBeTakenNamesNoCodeAndSaysSo() {
        let helperUnread = Machine(driver: { .running }, helper: { throw NotReadAgain() })
        for machine in [Self.unreadable, helperUnread] {
            let failure = PerformExit.classify(Self.stoppedOnTheWire, flavor: .development, machine: machine, cli: "lowtalker")
            #expect(failure.exit == nil)
            #expect(failure.said.contains("why the helper could not be reached was not read"))
        }
    }

    /// Only an unreachable helper is worth reading the machine for.
    @Test func aFailureThatIsNotTheHelperIsOneAndReadsNothing() {
        let moved = RouteStopped(performed: [], cause: TypingStopped(typed: 2, of: 5, cause: ScreenUnreadable.wrongApp(wanted: "com.apple.TextEdit", frontmost: "com.apple.Terminal")))
        let failure = PerformExit.classify(moved, flavor: .development, machine: Self.unreadable, cli: "lowtalker")
        #expect(failure.exit == nil)
        #expect(failure.said == "\(moved)")
    }

    @Test func theCodesAreDistinctAndClearOfTheOnesTakenAlready() {
        let codes = PerformExit.allCases.map(\.rawValue)
        #expect(Set(codes).count == codes.count)
        #expect(codes.allSatisfy { ![0, 1, 64].contains($0) })
    }
}
