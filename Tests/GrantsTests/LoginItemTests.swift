import Grants
import ServiceManagement
import Synchronization
import Testing

private struct Refused: Error, Equatable {}

/// A Login Items list a test controls: a status, and what registering and unregistering
/// make of it - or a refusal, as macOS gives for an item switched off in System Settings.
private final class FakeService: LoginItemService {
    private let status_: Mutex<SMAppService.Status>
    private let refusing: Bool

    init(status: SMAppService.Status, refusing: Bool = false) {
        status_ = Mutex(status)
        self.refusing = refusing
    }

    var status: SMAppService.Status { status_.withLock { $0 } }

    func register() throws {
        if refusing { throw Refused() }
        status_.withLock { $0 = .enabled }
    }

    func unregister() throws {
        if refusing { throw Refused() }
        status_.withLock { $0 = .notRegistered }
    }
}

@Suite struct LoginItemTests {
    @Test(arguments: [
        (SMAppService.Status.enabled, LoginItemStatus.on),
        (.notRegistered, .off),
        (.requiresApproval, .requiresApproval),
        (.notFound, .notFound),
    ])
    func everyStatusMacOSReportsReadsAsItsOwnState(status: SMAppService.Status, reads: LoginItemStatus) {
        #expect(LoginItem(service: FakeService(status: status)).current == reads)
    }

    @Test func choosingOnRegistersAndReadsBackOn() throws {
        let item = LoginItem(service: FakeService(status: .notRegistered))
        #expect(try item.choose(true) == .on)
        #expect(item.current == .on)
    }

    @Test func choosingOffUnregistersAndReadsBackOff() throws {
        let item = LoginItem(service: FakeService(status: .enabled))
        #expect(try item.choose(false) == .off)
    }

    /// An item switched off in System Settings is not switched back on from the app: the
    /// refusal reaches the caller, and the status still says where it can be allowed.
    @Test func aRefusedChoiceThrowsAndLeavesTheStatusSayingWhy() {
        let item = LoginItem(service: FakeService(status: .requiresApproval, refusing: true))
        #expect(throws: Refused.self) { try item.choose(true) }
        #expect(item.current == .requiresApproval)
    }
}
