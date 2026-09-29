import Foundation

/// An HTTP/1.1 request line and its headers, which say how much body follows.
///
/// [LAW:parse-dont-validate] A head in hand has a method, a path and headers; `parse` is the
/// only way to make one.
struct RequestHead: Sendable {
    let method: String
    /// The target's path, its query cut off.
    let path: String
    /// The target's query, by name, percent-decoded.
    let query: [String: String]
    /// Header names lower-cased, as HTTP compares them.
    let headers: [String: String]

    /// The bytes before the blank line that ends a request's headers.
    static func parse(_ bytes: Data) throws(APIError) -> RequestHead {
        let lines = lines(bytes)
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            throw .malformed("\"\(lines[0])\" is not an HTTP/1.1 request line")
        }
        let target = requestLine[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let query = URLComponents(string: "?" + (target.dropFirst().first ?? ""))?.queryItems ?? []
        return RequestHead(
            method: String(requestLine[0]),
            path: String(target[0]),
            query: Dictionary(query.map { ($0.name, $0.value ?? "") }) { first, _ in first },
            headers: try fields(lines.dropFirst())
        )
    }

    /// Header lines as a map from lower-cased name to value: a request's, or a
    /// multipart field's.
    static func fields(_ bytes: Data) throws(APIError) -> [String: String] {
        try fields(lines(bytes)[...])
    }

    private static func fields(_ lines: ArraySlice<String>) throws(APIError) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw .malformed("the header line \"\(line)\" has no colon") }
            // A repeated field is its values joined by commas (RFC 9110 §5.3), so two
            // content-lengths read as one that is not a byte count, and are refused.
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.merge([line[..<colon].lowercased(): value]) { "\($0), \($1)" }
        }
        return headers
    }

    /// Latin-1, as HTTP header bytes are read: every byte is a character, so decoding
    /// cannot fail.
    private static func lines(_ bytes: Data) -> [String] {
        String(data: bytes, encoding: .isoLatin1)!.components(separatedBy: "\r\n")
    }

    /// How many body bytes follow the head. Every request this server answers carries
    /// a body of declared length or none, so a chunked body is refused rather than read.
    func bodyLength(limit: Int) throws(APIError) -> Int {
        guard headers["transfer-encoding"] == nil else { throw .lengthRequired }
        guard let declared = headers["content-length"] else { return 0 }
        guard let length = Int(declared), length >= 0 else { throw .malformed("content-length \"\(declared)\" is not a byte count") }
        guard length <= limit else { throw .tooLarge(bytes: length, limit: limit) }
        return length
    }
}

/// An HTTP/1.1 response, whole: each one closes its connection once written.
struct HTTPResponse: Sendable, Equatable {
    let status: Status
    let contentType: String
    let body: Data

    /// The bytes on the wire. `connection: close` because the server reads one request per
    /// connection; a client that asked to keep it alive opens another.
    var wire: Data {
        let head = "HTTP/1.1 \(status.rawValue) \(status.reason)\r\n"
            + "content-type: \(contentType)\r\n"
            + "content-length: \(body.count)\r\n"
            + "connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// Every status this server answers with. [LAW:types-are-the-program] A status the
/// server has no reason phrase for cannot be sent.
enum Status: Int, Sendable, Codable {
    case ok = 200
    case badRequest = 400
    case notFound = 404
    case lengthRequired = 411
    case contentTooLarge = 413
    case internalServerError = 500
    case serviceUnavailable = 503

    var reason: String {
        switch self {
        case .ok: "OK"
        case .badRequest: "Bad Request"
        case .notFound: "Not Found"
        case .lengthRequired: "Length Required"
        case .contentTooLarge: "Content Too Large"
        case .internalServerError: "Internal Server Error"
        case .serviceUnavailable: "Service Unavailable"
        }
    }
}
