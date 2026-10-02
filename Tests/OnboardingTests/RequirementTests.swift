import Grants
import Testing
@testable import Onboarding

/// The list a person acts on. What is checked is the contract every surface depends on -
/// that a requirement carries a step exactly when something is left to do, that no state
/// is left without one, and that a fact nobody could read never reads as fine.
/// [LAW:behavior-not-structure]
@Suite struct RequirementTests {
    static func readings(for row: Requirement.Row) -> [String] {
        Requirement.readings.filter { $0.row == row }.map(\.reading)
    }

    // MARK: - the input method

    /// Switched on asks for nothing; switched off sends the reader to the step that asks.
    @Test func onlyASwitchedOnInputMethodAsksNothing() {
        #expect(Requirement.inputMethod(switchedOn: true).met)
        let off = Requirement.inputMethod(switchedOn: false)
        #expect(!off.met)
        #expect(off.step?.contains(GuidedSetup.title) == true)
    }

    // MARK: - the vocabulary README keeps a copy of

    /// Each row's readings in the table are the ones the row prints. [LAW:one-source-of-truth]
    @Test func eachRowsReadingsAreTheOnesItPrints() {
        let answers: [MicrophoneAuthorization.Withheld?] = [nil] + MicrophoneAuthorization.Withheld.allCases
        #expect(Self.readings(for: .microphone) == answers.map { Requirement.microphone($0).reads })
        #expect(Self.readings(for: .inputMethod) == [true, false].map { Requirement.inputMethod(switchedOn: $0).reads })
    }

    /// Every row is in the table, and no row's readings are borrowed from another's. A
    /// gap here is invisible to the check that reads it: README would be held to the rows
    /// that happened to be listed and silently unheld on the rest.
    @Test func everyRowHasReadingsOfItsOwnInTheTable() {
        for row in Requirement.Row.allCases {
            #expect(!Self.readings(for: row).isEmpty, "\(row.rawValue) has no readings in the table")
        }
        #expect(Requirement.readings.count == Requirement.Row.allCases.reduce(0) { $0 + Self.readings(for: $1).count })
    }

    // MARK: - the list

    /// A fact nobody could read never counts as met, so a report cannot come out ready
    /// on the strength of a reading nobody took. [LAW:no-silent-failure]
    @Test func aRequirementThatCouldNotBeReadIsNeverMet() {
        struct Unreadable: Error, CustomStringConvertible { var description: String { "why" } }
        let requirement = Requirement.unreadable(.inputMethod, Unreadable())
        #expect(!requirement.met)
        #expect(requirement.step?.contains("why") == true)
        #expect(!Readiness([requirement]).ready)
    }

    /// Every requirement is shown every time, met ones included: a list that printed only
    /// what was wrong would leave a reader unable to tell "checked and fine" from "never
    /// checked". [LAW:dataflow-not-control-flow]
    @Test func theListShowsEveryRequirementWhetherOrNotItNeedsAnything() {
        let readiness = Readiness([
            .microphone(nil),
            .inputMethod(switchedOn: true),
        ])
        #expect(readiness.ready)
        #expect(readiness.description.contains("Microphone: allowed"))
        #expect(readiness.description.contains("Input method: switched on"))
    }

    @Test func oneUnmetRequirementIsEnoughToStopTheList() {
        let readiness = Readiness([
            .microphone(nil),
            .inputMethod(switchedOn: false),
        ])
        #expect(!readiness.ready)
        #expect(readiness.unmet.map(\.row) == [.inputMethod])
    }
}
