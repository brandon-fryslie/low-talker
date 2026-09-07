import Foundation
import KeyboardService
import Security
import Testing
@testable import lowtalker_keyboardd

/// The authorization boundary of the root keystroke service, checked against the one
/// process whose identity and audit token this test can hold: its own.
/// [LAW:behavior-not-structure]
@Suite struct CallerIdentityTests {
    @Test func aStringThatIsNotARequirementIsRefused() throws {
        let refusal = #expect(throws: CallerIdentity.Refused.self) { try CallerIdentity(requirement: "this is not a requirement") }
        guard case .malformedRequirement("this is not a requirement", _)? = refusal else {
            Issue.record("refused as \(String(describing: refusal)), not as a malformed requirement")
            return
        }
    }

    @Test func aCallerSatisfyingTheRequirementIsAdmitted() throws {
        let identity = try CallerIdentity(requirement: try OwnProcess.requirement())
        try identity.check(auditToken: try OwnProcess.auditToken())
    }

    @Test func aCallerNotSatisfyingTheRequirementIsRefusedByIdentity() throws {
        let identity = try CallerIdentity(requirement: "identifier \"\(try OwnProcess.codeIdentifier()).elsewhere\"")
        let refusal = #expect(throws: CallerIdentity.Refused.self) { try identity.check(auditToken: try OwnProcess.auditToken()) }
        guard case .wrongIdentity? = refusal else {
            Issue.record("refused as \(String(describing: refusal)), not by identity")
            return
        }
    }

    /// A token naming no process is refused before any requirement is consulted.
    @Test func aTokenNamingNoProcessIsRefusedAsUnidentified() throws {
        let identity = try CallerIdentity(requirement: try OwnProcess.requirement())
        var token = try OwnProcess.auditToken()
        token.val.5 = 99_999_999
        let refusal = #expect(throws: CallerIdentity.Refused.self) { try identity.check(auditToken: token) }
        guard case .unidentified? = refusal else {
            Issue.record("refused as \(String(describing: refusal)), not as unidentified")
            return
        }
    }

    /// The token read off a real connection is the connecting process's own: the private
    /// key still answers, boxed as the eight unsigned ints this side unpacks, and the
    /// process it names satisfies the requirement that process satisfies.
    @Test func aConnectionsAuditTokenNamesTheConnectingProcess() throws {
        let reader = TokenReader()
        let listener = NSXPCListener.anonymous()
        listener.delegate = reader
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperService.self)
        connection.resume()
        let proxy = try #require(connection.remoteObjectProxyWithErrorHandler { _ in } as? HelperService)
        proxy.releaseAll { _ in }
        let token = try #require(reader.await())
        let identity = try CallerIdentity(requirement: try OwnProcess.requirement())
        try identity.check(auditToken: token)
        connection.invalidate()
        withExtendedLifetime(listener) {}
    }
}

/// A listener delegate that keeps the token of whoever connects and admits nobody.
private final class TokenReader: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let arrived = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var token: audit_token_t?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        lock.lock(); token = connection.callerAuditToken; lock.unlock()
        arrived.signal()
        return false
    }

    func await() -> audit_token_t? {
        guard arrived.wait(timeout: .now() + .seconds(2)) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return token
    }
}
