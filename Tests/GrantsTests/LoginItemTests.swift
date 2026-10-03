import Grants
import ServiceManagement
import Testing

private struct Refused: Error {}

/// A Login Items list a test controls: a status, and what registering and unregistering
/// make of it - or a refusal that leaves it where it was, as macOS gives for an item
/// switched off in System Settings.
private final class FakeService: LoginItemService {
    private(set) var status: SMAppService.Status
    private let refusing: Bool

    init(status: SMAppService.Status, refusing: Bool = false) {
        self.status = status
        self.refusing = refusing
    }

    func register() throws {
        if refusing { throw Refused() }
        status = .enabled
    }

    func unregister() throws {
        if refusing { throw Refused() }
        status = .notRegistered
    }
}

@Suite struct LoginItemTests {
    /// A never-registered app reads `notFound`, so it reads off with the unregistered one.
    @Test(arguments: [
        (SMAppService.Status.enabled, LoginItemStatus.on),
        (.notRegistered, .off),
        (.notFound, .off),
        (.requiresApproval, .requiresApproval),
    ])
    func everyStatusMacOSReportsReadsAsItsOwnState(status: SMAppService.Status, reads: LoginItemStatus) {
        #expect(LoginItem(service: FakeService(status: status)).current == reads)
    }

    @Test func aStatusFromALaterMacOSReadsAsUnrecognizedRatherThanTrapping() throws {
        let later = try #require(SMAppService.Status(rawValue: 99))
        #expect(LoginItem(service: FakeService(status: later)).current == .unrecognized(99))
    }

    @Test(arguments: [SMAppService.Status.notRegistered, .notFound])
    func togglingAnItemNotChosenRegistersIt(status: SMAppService.Status) throws {
        let item = LoginItem(service: FakeService(status: status))
        #expect(try item.toggle() == .on)
        #expect(item.current == .on)
    }

    /// An item waiting on System Settings is chosen, so a click takes it out of the list
    /// rather than asking again for what is already asked.
    @Test(arguments: [SMAppService.Status.enabled, .requiresApproval])
    func togglingAChosenItemUnregistersIt(status: SMAppService.Status) throws {
        #expect(try LoginItem(service: FakeService(status: status)).toggle() == .off)
    }

    /// A refusal that leaves the item waiting on System Settings is answered there.
    @Test func aRefusalLeftWaitingOnSystemSettingsIsAllowedOnlyThere() {
        let item = LoginItem(service: FakeService(status: .requiresApproval, refusing: true))
        #expect { try item.toggle() } throws: { ($0 as? LoginItemRefusal)?.allowedOnlyInSystemSettings == true }
    }

    /// Any other refusal has nothing for the person to do in System Settings.
    @Test func aRefusalOfAnUnregisteredItemIsNotSentToSystemSettings() {
        let item = LoginItem(service: FakeService(status: .notFound, refusing: true))
        #expect { try item.toggle() } throws: { ($0 as? LoginItemRefusal)?.allowedOnlyInSystemSettings == false }
    }
}
