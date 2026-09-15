import Testing
@testable import DriverExtension

/// The verdict table, over every reading the machine can produce rather than over the
/// handful this Mac happens to be in. The table is the contract `scripts/virtual-hid-driver`
/// prints, `expect` asserts and README.md documents, so what is checked here is the word
/// each combination yields - never how the switch is written. [LAW:behavior-not-structure]
@Suite struct DriverStateTests {
    /// The seven combinations that have a name of their own. Everything else is residue,
    /// and any registration this build cannot read is unknown whatever surrounds it.
    static let named: [DriverFacts: DriverState] = [
        DriverFacts(payload: .none, receipt: nil, registration: .unregistered, ioNode: false, elementsReceipt: nil): .absent,
        DriverFacts(payload: .both, receipt: "8.4.0", registration: .unregistered, ioNode: false, elementsReceipt: nil): .installedInactive,
        DriverFacts(payload: .both, receipt: "8.4.0", registration: .waiting, ioNode: false, elementsReceipt: nil): .awaitingApproval,
        DriverFacts(payload: .both, receipt: "8.4.0", registration: .disabled, ioNode: false, elementsReceipt: nil): .disabled,
        DriverFacts(payload: .both, receipt: "8.4.0", registration: .enabled, ioNode: false, elementsReceipt: nil): .enabled,
        DriverFacts(payload: .both, receipt: "8.4.0", registration: .enabled, ioNode: true, elementsReceipt: nil): .running,
        DriverFacts(payload: .none, receipt: nil, registration: .pendingReboot, ioNode: false, elementsReceipt: nil): .pendingReboot,
    ]

    /// All 84 of them. An arm that matched one case too many, or a key that quietly
    /// stopped being reachable, survives any example anyone thought to write down.
    @Test func everyCombinationOfReadingsLandsOnTheWordTheTableNames() {
        for payload in Payload.allCases {
            for receipt in [nil, "8.4.0"] as [String?] {
                for registration in Registration.allCases {
                    for ioNode in [false, true] {
                        let facts = DriverFacts(payload: payload, receipt: receipt, registration: registration, ioNode: ioNode, elementsReceipt: nil)
                        let unreadable = registration == .unknown || registration == .ambiguous
                        let want = unreadable ? .unknown : (Self.named[facts] ?? .residue)
                        #expect(DriverState(facts) == want, "\(facts)")
                    }
                }
            }
        }
    }

    /// The receipt's version never moves a verdict; only whether one is held does. A
    /// table that read the version would make every package upgrade a new state.
    @Test func theReceiptVersionChangesNoVerdict() {
        for (facts, want) in Self.named where facts.receipt != nil {
            let upgraded = DriverFacts(payload: facts.payload, receipt: "99.0.0", registration: facts.registration, ioNode: facts.ioNode, elementsReceipt: nil)
            #expect(DriverState(upgraded) == want)
        }
    }

    /// Karabiner-Elements being installed is a fact about the Mac, not about where the
    /// driver stands, so every machine reads the same word with or without it.
    @Test func karabinerElementsChangesNoVerdict() {
        for (facts, want) in Self.named {
            let shared = DriverFacts(payload: facts.payload, receipt: facts.receipt, registration: facts.registration, ioNode: facts.ioNode, elementsReceipt: "15.5.0")
            #expect(DriverState(shared) == want)
        }
    }

    /// The table a reader gets names Karabiner-Elements beside the driver's own readings,
    /// held or not, so the shared payload is visible before `install` or `remove` runs.
    @Test func theFactTableNamesKarabinerElementsEitherWay() {
        let absent = DriverFacts(payload: .none, receipt: nil, registration: .unregistered, ioNode: false, elementsReceipt: nil)
        let held = DriverFacts(payload: .both, receipt: "8.4.0", registration: .enabled, ioNode: true, elementsReceipt: "15.5.0")
        #expect(absent.description.contains("Karabiner-Elements none"))
        #expect(held.description.contains("Karabiner-Elements 15.5.0"))
    }

    /// Removal's early exit reads `absent` and `pending-reboot` as "nothing left to do",
    /// so a machine still holding a payload or a receipt must never reach either word.
    @Test func aMachineStillHoldingSomethingIsNeverReportedAsFinished() {
        for payload in Payload.allCases {
            for receipt in [nil, "8.4.0"] as [String?] {
                for ioNode in [false, true] {
                    for registration in [Registration.unregistered, .pendingReboot] {
                        let facts = DriverFacts(payload: payload, receipt: receipt, registration: registration, ioNode: ioNode, elementsReceipt: nil)
                        let finished = DriverState(facts) == .absent || DriverState(facts) == .pendingReboot
                        #expect(finished == (payload == .none && receipt == nil && !ioNode))
                    }
                }
            }
        }
    }

    /// The words themselves. `expect <verdict>`, README.md and the app all spell them,
    /// and a rename that only touched the enum would leave those three reading a word
    /// this program no longer emits. [LAW:one-source-of-truth]
    @Test func theVerdictWordsAreTheOnesEveryReaderSpells() {
        #expect(Set(DriverState.allCases.map(\.rawValue)) == [
            "absent", "installed-inactive", "awaiting-approval", "disabled",
            "enabled", "running", "pending-reboot", "residue", "unknown",
        ])
    }
}
