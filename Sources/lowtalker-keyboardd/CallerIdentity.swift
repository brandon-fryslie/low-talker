import Foundation
import Security

/// Whether the process on the other end of a connection is allowed to press keys.
///
/// This daemon runs as root and posts keystrokes into whatever the user is looking at, so
/// the Mach service is a way to type into the operator's own session. The service is
/// reachable by anything that can talk to launchd, which is everything, so the boundary
/// has to be the caller's identity rather than its reach.
///
/// [LAW:parse-dont-validate] Asked once, at connection time, and a connection that fails
/// is refused whole rather than checked again per keystroke - a caller that could change
/// identity mid-connection is not a thing that exists, and re-asking per report would put
/// a code-signature check in front of every key.
struct CallerIdentity {
    /// The code-signing requirement a caller must satisfy.
    ///
    /// Read at startup rather than compiled in, so the requirement this daemon enforces is
    /// a fact of the installation and not of the build. [LAW:one-source-of-truth] A build
    /// that hard-coded it would give the dev path and the shipped path two different
    /// binaries, and the one an agent can verify would not be the one that ships.
    let requirement: SecRequirement

    enum Refused: Error, CustomStringConvertible {
        case malformedRequirement(String, OSStatus)
        case unidentified(OSStatus)
        case noAuditToken
        case wrongIdentity(OSStatus)

        var description: String {
            switch self {
            case .malformedRequirement(let text, let status):
                "the caller requirement \(text.debugDescription) is not a code signing requirement (OSStatus \(status))"
            case .noAuditToken:
                "the connection would not say which process is on the other end, so it cannot be identified"
            case .unidentified(let status):
                "the calling process could not be identified (OSStatus \(status))"
            case .wrongIdentity(let status):
                "the calling process does not satisfy this helper's caller requirement (OSStatus \(status))"
            }
        }
    }

    init(requirement text: String) throws {
        var parsed: SecRequirement?
        let status = SecRequirementCreateWithString(text as CFString, [], &parsed)
        guard status == errSecSuccess, let parsed else {
            throw Refused.malformedRequirement(text, status)
        }
        requirement = parsed
    }

    /// Answers for the process the audit token names, and nothing else.
    ///
    /// The audit token and not the pid: a pid can be reused between the moment it is read
    /// and the moment it is checked, and the check would then be of whichever process
    /// inherited the number. The token names one process for as long as it exists, which
    /// is the whole reason the kernel hands one over. [LAW:no-silent-failure]
    func check(auditToken: audit_token_t) throws {
        var token = auditToken
        let attributes = [
            kSecGuestAttributeAudit: Data(bytes: &token, count: MemoryLayout<audit_token_t>.size),
        ] as CFDictionary

        var code: SecCode?
        let found = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard found == errSecSuccess, let code else { throw Refused.unidentified(found) }

        let valid = SecCodeCheckValidity(code, [], requirement)
        guard valid == errSecSuccess else { throw Refused.wrongIdentity(valid) }
    }
}

extension NSXPCConnection {
    /// The token naming the process at the other end.
    ///
    /// `NSXPCConnection` publishes a pid and not this, and a pid is the wrong question: it
    /// can be reused between being read and being checked, so a check made on one is of
    /// whichever process inherited the number. The token is there - every XPC connection
    /// carries one, and this is how a helper is meant to identify its caller - it is
    /// simply not in the public header, so it is read by name.
    ///
    /// **Absent means refused, never allowed.** [LAW:no-silent-failure] If a future macOS
    /// stops answering, this returns nil and the connection is turned away; the failure
    /// this arrangement must never have is a root keystroke service that starts accepting
    /// everyone because the identity check quietly stopped working.
    var callerAuditToken: audit_token_t? {
        guard let boxed = value(forKey: "auditToken") as? NSValue else { return nil }
        var token = audit_token_t()
        guard boxed.objCType.withMemoryRebound(to: CChar.self, capacity: 1, { String(cString: $0) })
            .isEmpty == false else { return nil }
        withUnsafeMutableBytes(of: &token) { boxed.getValue($0.baseAddress!, size: $0.count) }
        return token
    }
}
