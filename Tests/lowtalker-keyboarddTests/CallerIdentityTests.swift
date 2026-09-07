import Foundation
import KeyboardService
import Security
import Testing
@testable import lowtalker_keyboardd

/// The authorization boundary of the root keystroke service, checked against the one
/// process whose identity and audit token this test can hold: its own. Real code signing
/// and a real token, no root. [LAW:behavior-not-structure]
@Suite struct CallerIdentityTests {
    /// This process's audit token, from the kernel.
    private var ownToken: audit_token_t {
        get throws {
            var token = audit_token_t()
            var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &token) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count) }
            }
            try #require(result == KERN_SUCCESS)
            return token
        }
    }

    /// This process's code signing identifier, off its own signature.
    private var ownIdentifier: String {
        get throws {
            var running: SecCode?
            try #require(SecCodeCopySelf([], &running) == errSecSuccess)
            var code: SecStaticCode?
            try #require(SecCodeCopyStaticCode(try #require(running), [], &code) == errSecSuccess)
            var information: CFDictionary?
            try #require(SecCodeCopySigningInformation(try #require(code), [], &information) == errSecSuccess)
            let signing = try #require(information as? [CFString: Any])
            return try #require(signing[kSecCodeInfoIdentifier] as? String)
        }
    }

    @Test func aStringThatIsNotARequirementIsRefused() throws {
        let refusal = #expect(throws: CallerIdentity.Refused.self) { try CallerIdentity(requirement: "this is not a requirement") }
        guard case .malformedRequirement("this is not a requirement", _)? = refusal else {
            Issue.record("refused as \(String(describing: refusal)), not as a malformed requirement")
            return
        }
    }

    @Test func aCallerSatisfyingTheRequirementIsAdmitted() throws {
        let identity = try CallerIdentity(requirement: "identifier \"\(try ownIdentifier)\"")
        try identity.check(auditToken: try ownToken)
    }

    @Test func aCallerNotSatisfyingTheRequirementIsRefusedByIdentity() throws {
        let identity = try CallerIdentity(requirement: "identifier \"\(try ownIdentifier).elsewhere\"")
        let refusal = #expect(throws: CallerIdentity.Refused.self) { try identity.check(auditToken: try ownToken) }
        guard case .wrongIdentity? = refusal else {
            Issue.record("refused as \(String(describing: refusal)), not by identity")
            return
        }
    }

    /// A token naming no process is refused before any requirement is consulted.
    @Test func aTokenNamingNoProcessIsRefusedAsUnidentified() throws {
        let identity = try CallerIdentity(requirement: "identifier \"\(try ownIdentifier)\"")
        var token = try ownToken
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
        connection.remoteObjectInterface = NSXPCInterface(with: KeyboardService.self)
        connection.resume()
        let proxy = try #require(connection.remoteObjectProxyWithErrorHandler { _ in } as? KeyboardService)
        proxy.releaseAll { _ in }
        let token = try #require(reader.await())
        let identity = try CallerIdentity(requirement: "identifier \"\(try ownIdentifier)\"")
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
