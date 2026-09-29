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

/// A numeric address of an interface on this Mac, off loopback: `192.168.1.20`, `fe80::1`,
/// or `0.0.0.0` for every interface at once.
public struct InterfaceAddress: Hashable, Sendable, CustomStringConvertible {
    /// As written in the config; it parsed as an IPv4 or IPv6 literal.
    public let literal: String
    public let isIPv6: Bool

    /// The address `literal` names, or why it names none a server can be told to take.
    public init(_ literal: String) throws(ServeBindingError) {
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, literal, &v4) == 1 {
            guard UInt32(bigEndian: v4.s_addr) >> 24 != 127 else { throw .loopbackInterface(literal) }
            isIPv6 = false
        } else if inet_pton(AF_INET6, literal, &v6) == 1 {
            guard withUnsafeBytes(of: v6, Array.init) != withUnsafeBytes(of: in6addr_loopback, Array.init) else { throw .loopbackInterface(literal) }
            isIPv6 = true
        } else {
            throw .notAnAddress(literal)
        }
        self.literal = literal
    }

    public var description: String { literal }
}

/// The key a caller off loopback must send as `Authorization: Bearer <token>`.
public struct BearerToken: Hashable, Sendable, CustomStringConvertible {
    private let value: Data

    /// RFC 6750's token68: letters, digits and `-._~+/`, then any `=` padding. Anything else
    /// could not arrive whole in the header a client sends it in.
    public init(_ value: String) throws(ServeBindingError) {
        guard value.wholeMatch(of: /[A-Za-z0-9\-._~+\/]+=*/) != nil else { throw .tokenUnsendable }
        self.value = Data(value.utf8)
    }

    /// Whether `authorization` is `Bearer ` and this token. The scheme's case does not count
    /// (RFC 9110); the comparison of the token takes as long whatever the header holds, so
    /// timing it says nothing about how much of a guess was right.
    func isPresented(in authorization: String?) -> Bool {
        guard let authorization, let space = authorization.firstIndex(of: " "),
              authorization[..<space].lowercased() == "bearer" else { return false }
        let presented = Data(authorization[authorization.index(after: space)...].utf8)
        let difference = zip(presented, value).reduce(UInt8(presented.count == value.count ? 0 : 1)) { $0 | ($1.0 ^ $1.1) }
        return difference == 0
    }

    /// Never the secret, so no report or log line can leak it.
    public var description: String { "(bearer token)" }
}

/// Why a `[serve]` table names no binding, in the words of the keys it is written with.
public enum ServeBindingError: Error, Equatable, Sendable, CustomStringConvertible {
    case notAnAddress(String)
    case loopbackInterface(String)
    case tokenUnsendable
    case interfaceWithoutToken(String)
    case tokenWithoutInterface

    public var description: String {
        switch self {
        case .notAnAddress(let literal):
            "serve.interface \"\(literal)\" is not a numeric IPv4 or IPv6 address"
        case .loopbackInterface(let literal):
            "serve.interface \"\(literal)\" is loopback, where the server listens when serve.interface is left out; remove it"
        case .tokenUnsendable:
            "serve.token may hold only letters, digits and -._~+/, then any = padding, so a client can send it as a bearer token"
        case .interfaceWithoutToken(let literal):
            "serve.interface \"\(literal)\" is off loopback, so serve.token is required: every caller there must send it as a bearer token"
        case .tokenWithoutInterface:
            "serve.token is set but serve.interface is not, and on loopback every caller is answered whatever token it sends; set serve.interface or remove serve.token"
        }
    }
}
