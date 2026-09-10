import LowTalkerCore
import Pointing
import Testing
@testable import Typing

/// The refusal that stands between an agent's click and somebody else's Allow button,
/// asked without a window server.
///
/// It lives on `down` rather than `check`, because a press is what can answer a prompt and
/// a motion report is not - so these are the branches that decide whether a press reaches
/// the device at all. Asserted as the contract rather than by watching the reading happen:
/// what matters is that a refused press posts nothing, and that an unrefused one posts
/// exactly one report. [LAW:behavior-not-structure]
@Suite @MainActor struct GuardedMouseTests {
    /// A mouse over a device that records, reading whatever screen the test states.
    private func mouse(seeing alerts: @escaping @MainActor () throws -> Void) -> (GuardedMouse, RecordingPointing) {
        let device = RecordingPointing()
        let guarded = GuardedMouse(
            pointing: device,
            queue: DeviceQueue(),
            interrupt: Interrupt(),
            screen: TargetApp(bundleID: BundleID(rawValue: "com.example.nothing"), interrupt: Interrupt()),
            alerts: alerts
        )
        return (guarded, device)
    }

    /// The whole point of the rule. A refusal raised after the report went out would pass
    /// on the error alone, so the empty log is the assertion that matters: the press has to
    /// be stopped, not reported on afterwards.
    @Test func aPressIsRefusedWhileAnAlertIsOverTheScreen() async {
        let (guarded, device) = mouse(seeing: { throw AlertOnScreen(count: 1) })
        await #expect(throws: AlertOnScreen.self) { try await guarded.down(.left) }
        #expect(device.log.isEmpty)
    }

    /// An unreadable screen is refused on the same terms as an alert on it: "whether
    /// anything is over the screen is unknown" may not be spent as "nothing is".
    /// [LAW:no-silent-failure]
    @Test func aPressIsRefusedWhenWhatIsOverTheScreenCannotBeRead() async {
        let (guarded, device) = mouse(seeing: { throw AlertsUnreadable.answeredWithSomethingElse })
        await #expect(throws: AlertsUnreadable.self) { try await guarded.down(.left) }
        #expect(device.log.isEmpty)
    }

    @Test func aPressGoesOutWhenNothingIsOverTheScreen() async throws {
        let (guarded, device) = mouse(seeing: {})
        try await guarded.down(.left)
        #expect(device.log == ["down 1"])
    }

    /// Why the reading moved off `check`: a move posts up to 64 reports for one click and
    /// none of them can answer a prompt, so a reading there would be paid for 64 times and
    /// buy nothing. Stated with an alert standing over the screen - a move that asked would
    /// throw here, and both reports arrive instead.
    @Test func aMoveAndAScrollGoOutWithAnAlertStandingOverTheScreen() async throws {
        let (guarded, device) = mouse(seeing: { throw AlertOnScreen(count: 1) })
        try await guarded.move(by: Move(x: Count(clamping: 3), y: Count(clamping: 4)))
        try await guarded.scroll(by: Scroll(vertical: Count(clamping: 5), horizontal: Count(clamping: 0)))
        #expect(device.log == ["move 3 4", "scroll 5 0"])
    }
}
