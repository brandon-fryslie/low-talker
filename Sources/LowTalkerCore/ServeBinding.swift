import CryptoKit
import Foundation

/// Where the transcription server listens, and what a caller must show to be answered there
/// (epic low-serve-axq).
///
/// [LAW:types-are-the-program] Off loopback, a token is part of the address: an interface
/// with no token cannot be written down, so no server can listen off loopback unguarded.
/// On loopback every caller is answered, token or none, because local clients send
/// placeholder keys.
public enum ServeBinding: Hashable, Sendable, CustomStringConvertible {
    case loopback
    case interface(InterfaceAddress, token: BearerToken)

    /// Whether a request carrying this `Authorization` header value is answered.
    ///
    /// [LAW:single-enforcer] The one test of a caller's key, for REST and Realtime alike.
    public func admits(authorization: String?) -> Bool {
        switch self {
        case .loopback: true
        case .interface(_, let token): token.isPresented(in: authorization)
        }
    }

    /// Never the token: this is what the config report and the log print.
    public var description: String {
        switch self {
        case .loopback: "loopback"
        case .interface(let address, _): "\(address), bearer token required"
        }
    }
}

/// The numeric address of one interface on this Mac, off loopback: `192.168.1.20`, or
/// `fd7a:115c:a1e0::1`.
public struct InterfaceAddress: Hashable, Sendable, CustomStringConvertible {
    /// As written in the config; it parsed as an IPv4 or IPv6 literal.
    public let literal: String
    public let isIPv6: Bool

    /// The address `literal` names, or why it names none a server can be told to take.
    public init(_ literal: String) throws(ServeBindingError) {
        var v4 = in_addr()
        var v6 = in6_addr()
        let bytes: [UInt8]
        if inet_pton(AF_INET, literal, &v4) == 1 {
            bytes = withUnsafeBytes(of: v4, Array.init)
            isIPv6 = false
        } else if inet_pton(AF_INET6, literal, &v6) == 1 {
            bytes = withUnsafeBytes(of: v6, Array.init)
            isIPv6 = true
        } else {
            throw .notAnAddress(literal)
        }
        guard !Self.takesInLoopback(bytes) else { throw .takesInLoopback(literal) }
        self.literal = literal
    }

    /// Loopback itself, the unspecified address that listens on every interface loopback
    /// among them, in either family, and IPv4 written as IPv6: every address a server could
    /// be told to take where local callers, sending placeholder keys, would reach it.
    private static func takesInLoopback(_ bytes: [UInt8]) -> Bool {
        let mapped = [UInt8](repeating: 0, count: 10) + [0xff, 0xff]
        let v4 = bytes.starts(with: mapped) ? Array(bytes.suffix(4)) : bytes
        return v4.allSatisfy { $0 == 0 } || v4 == [UInt8](repeating: 0, count: 15) + [1] || (v4.count == 4 && v4[0] == 127)
    }

    public var description: String { literal }
}

/// The key a caller off loopback must send as `Authorization: Bearer <token>`.
public struct BearerToken: Hashable, Sendable, CustomStringConvertible {
    /// Its SHA-256, never the token: two digests are one length whatever was sent, so
    /// comparing them takes as long for any guess, and the secret is not held.
    private let digest: Data

    /// RFC 6750's token68: letters, digits and `-._~+/`, then any `=` padding. Anything else
    /// could not arrive whole in the header a client sends it in.
    public init(_ value: String) throws(ServeBindingError) {
        guard value.wholeMatch(of: /[A-Za-z0-9\-._~+\/]+=*/) != nil else { throw .tokenUnsendable }
        digest = Data(SHA256.hash(data: Data(value.utf8)))
    }

    /// Whether `authorization` is `Bearer ` and this token. The scheme's case does not count
    /// (RFC 9110).
    func isPresented(in authorization: String?) -> Bool {
        guard let authorization, let space = authorization.firstIndex(of: " "),
              authorization[..<space].lowercased() == "bearer" else { return false }
        let presented = SHA256.hash(data: Data(authorization[authorization.index(after: space)...].utf8))
        return zip(presented, digest).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Never the secret, so no report or log line can leak it.
    public var description: String { "(bearer token)" }
}

/// Why a `[serve]` table names no binding, in the words of the keys it is written with.
public enum ServeBindingError: Error, Equatable, Sendable, CustomStringConvertible {
    case notAnAddress(String)
    case takesInLoopback(String)
    case tokenUnsendable
    case interfaceWithoutToken(String)
    case tokenWithoutInterface
    case emptyTable

    public var description: String {
        switch self {
        case .notAnAddress(let literal):
            "serve.interface \"\(literal)\" is not a numeric IPv4 or IPv6 address"
        case .takesInLoopback(let literal):
            "serve.interface \"\(literal)\" takes in loopback, where the server listens when serve.interface is left out and answers every caller; name one interface's own address, or remove it"
        case .tokenUnsendable:
            "serve.token may hold only letters, digits and -._~+/, then any = padding, so a client can send it as a bearer token"
        case .interfaceWithoutToken(let literal):
            "serve.interface \"\(literal)\" is off loopback, so serve.token is required: every caller there must send it as a bearer token"
        case .tokenWithoutInterface:
            "serve.token is set but serve.interface is not, and on loopback every caller is answered whatever token it sends; set serve.interface or remove serve.token"
        case .emptyTable:
            "serve.interface is missing: a [serve] heading somebody wrote on purpose cannot be read as the loopback they were already getting; add serve.interface and serve.token, or remove the heading"
        }
    }
}
