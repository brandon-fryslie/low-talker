import Foundation
import Security
import Testing

/// This process, as the one caller whose identity and audit token a test can hold: real
/// code signing and a real token, no root. [LAW:one-source-of-truth] Read here and nowhere
/// else, so every suite that plays the caller plays the same one.
enum OwnProcess {
    /// This process's audit token, from the kernel.
    static func auditToken() throws -> audit_token_t {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count) }
        }
        try #require(result == KERN_SUCCESS)
        return token
    }

    /// This process's code signing identifier, off its own signature.
    static func codeIdentifier() throws -> String {
        var running: SecCode?
        try #require(SecCodeCopySelf([], &running) == errSecSuccess)
        var code: SecStaticCode?
        try #require(SecCodeCopyStaticCode(try #require(running), [], &code) == errSecSuccess)
        var information: CFDictionary?
        try #require(SecCodeCopySigningInformation(try #require(code), [], &information) == errSecSuccess)
        let signing = try #require(information as? [CFString: Any])
        return try #require(signing[kSecCodeInfoIdentifier] as? String)
    }

    /// A requirement this process satisfies and a process signed as anything else does not.
    static func requirement() throws -> String {
        "identifier \"\(try codeIdentifier())\""
    }
}
