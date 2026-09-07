import CryptoKit
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
    /// The code-signing requirement a caller must satisfy: signed by the certificate that
    /// signed this helper.
    ///
    /// [LAW:one-source-of-truth] Read off this process's own signature rather than
    /// compiled in or handed over by whoever installed the job. The app, the CLI and this
    /// helper are signed together - by the dev identity `make signing-identity` makes, or
    /// by the Developer ID that ships them - so "whoever signed me" is the one statement
    /// of who may call that is true of every installation without anyone writing it down.
    /// A helper signed ad hoc has no certificate to name and does not start; an
    /// unidentified root keystroke service is the failure this exists to make impossible.
    let requirement: SecRequirement
    /// The requirement as text, for the log: an operator refused by it needs to know what
    /// it says.
    let text: String

    enum Refused: Error, CustomStringConvertible {
        case unsigned(OSStatus)
        case adHoc
        case malformedRequirement(String, OSStatus)
        case unidentified(OSStatus)
        case noAuditToken
        case wrongIdentity(OSStatus)

        var description: String {
            switch self {
            case .unsigned(let status):
                "this helper's own code signature could not be read (OSStatus \(status))"
            case .adHoc:
                "this helper is signed ad hoc, with no certificate to require of its callers; sign it with an identity (make helper)"
            case .malformedRequirement(let text, let status):
                "the caller requirement \(text.debugDescription) is not a code signing requirement (OSStatus \(status))"
            case .noAuditToken:
                "the connection would not say which process is on the other end, so it cannot be identified"
            case .unidentified(let status):
                "the calling process could not be identified (OSStatus \(status))"
            case .wrongIdentity(let status):
                "the calling process is not signed by this helper's certificate (OSStatus \(status))"
            }
        }
    }

    /// The identity of whoever signed this process, as a requirement of its callers.
    static func sameSignerAsThisProcess() throws -> CallerIdentity {
        var running: SecCode?
        let found = SecCodeCopySelf([], &running)
        guard found == errSecSuccess, let running else { throw Refused.unsigned(found) }
        var code: SecStaticCode?
        let pinned = SecCodeCopyStaticCode(running, [], &code)
        guard pinned == errSecSuccess, let code else { throw Refused.unsigned(pinned) }
        var information: CFDictionary?
        let read = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard read == errSecSuccess, let information = information as? [CFString: Any] else { throw Refused.unsigned(read) }
        // An ad hoc signature has no certificate chain at all, so the leaf is absent
        // rather than empty. [LAW:no-silent-failure]
        guard let chain = information[kSecCodeInfoCertificates] as? [SecCertificate], let leaf = chain.first else { throw Refused.adHoc }
        let fingerprint = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
        return try CallerIdentity(requirement: "certificate leaf = H\"\(fingerprint.map { String(format: "%02x", $0) }.joined())\"")
    }

    init(requirement text: String) throws {
        var parsed: SecRequirement?
        let status = SecRequirementCreateWithString(text as CFString, [], &parsed)
        guard status == errSecSuccess, let parsed else {
            throw Refused.malformedRequirement(text, status)
        }
        requirement = parsed
        self.text = text
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
        // Asked for only when the connection answers to the name, and the box unpacked
        // only when it says it holds an `audit_token_t` - eight unsigned ints. Key-value
        // coding raises for a key the object does not have, and `getValue` raises on a
        // size it did not expect; a raised exception in a root daemon is a crash and not
        // a refusal, and a private key is one a release can take away.
        guard responds(to: Selector(("auditToken"))),
              let boxed = value(forKey: "auditToken") as? NSValue,
              String(cString: boxed.objCType) == "{?=[8I]}" else { return nil }
        var token = audit_token_t()
        withUnsafeMutableBytes(of: &token) { boxed.getValue($0.baseAddress!, size: $0.count) }
        return token
    }
}
