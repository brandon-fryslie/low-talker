import AVFoundation
import LowTalkerCore
import Synchronization
import Testing

/// A TCC that a test controls: a status, and the decision the user makes at the prompt.
private final class FakeAuthority: MicrophoneAuthority {
    private let status_: Mutex<AVAuthorizationStatus>
    /// What the status becomes when the prompt is answered.
    private let decision: AVAuthorizationStatus

    init(status: AVAuthorizationStatus, decision: AVAuthorizationStatus = .authorized) {
        status_ = Mutex(status)
        self.decision = decision
    }

    func status() -> AVAuthorizationStatus { status_.withLock { $0 } }

    /// The user changed their mind in System Settings.
    func set(_ status: AVAuthorizationStatus) { status_.withLock { $0 = status } }

    func requestAccess() async -> Bool {
        set(decision)
        return decision == .authorized
    }
}

@Suite struct MicrophonePermissionTests {
    @Test(arguments: [
        (AVAuthorizationStatus.notDetermined, MicrophoneAuthorization.Withheld.notDetermined),
        (.denied, .denied),
        (.restricted, .restricted),
    ])
    func everyWayOfSayingNoIsWithheldWithItsReason(status: AVAuthorizationStatus, reason: MicrophoneAuthorization.Withheld) {
        let permission = MicrophonePermission(authority: FakeAuthority(status: status))
        #expect(permission.current == .withheld(reason))
        #expect(throws: reason) { try permission.current.grant() }
    }

    @Test func authorizedIsAGrant() throws {
        let permission = MicrophonePermission(authority: FakeAuthority(status: .authorized))
        guard case .granted(let grant) = permission.current else {
            Issue.record("authorized did not parse as granted")
            return
        }
        #expect(try permission.current.grant() == grant)
    }

    /// The request reports the user's decision, not the Bool: denied and restricted
    /// both answer false at the prompt and are told apart afterwards.
    @Test(arguments: [AVAuthorizationStatus.authorized, .denied, .restricted])
    func requestReportsTheDecision(decision: AVAuthorizationStatus) async {
        let authority = FakeAuthority(status: .notDetermined, decision: decision)
        let answer = await MicrophonePermission(authority: authority).request()
        #expect(answer == MicrophonePermission(authority: FakeAuthority(status: decision)).current)
    }

    /// The stream opens with where things stand and then yields each change, so a
    /// switch flipped in System Settings reaches the app without a relaunch.
    @Test func changesYieldTheCurrentValueThenEachChange() async throws {
        let authority = FakeAuthority(status: .notDetermined)
        var changes = MicrophonePermission(authority: authority).changes(every: .milliseconds(1)).makeAsyncIterator()

        #expect(await changes.next() == .withheld(.notDetermined))
        authority.set(.denied)
        #expect(await changes.next() == .withheld(.denied))
        authority.set(.authorized)
        #expect(await changes.next() == .granted(try MicrophonePermission(authority: authority).current.grant()))
        // Reads that see no change yield nothing: the next value out is the next change.
        authority.set(.restricted)
        #expect(await changes.next() == .withheld(.restricted))
    }
}
