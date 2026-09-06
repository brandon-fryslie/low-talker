import Foundation

/// pqrs's Unix domain stream framing, at package 8.4.0 and client protocol 7, read off
/// `unix_domain_stream/impl/protocol.hpp` rather than inferred from traffic.
///
/// A frame is a 4-byte big-endian body length, then the body: one type byte, and - for
/// the two types the protocol numbers - an 8-byte big-endian request id before the
/// payload. Nothing here touches a socket. Byte order is the part of a protocol that goes
/// wrong silently, and a frame read the wrong way round is still a well-formed frame; a
/// pure function is one that can be proven instead of only observed. [LAW:decomposition]
enum Frame: Equatable {
    /// The frame types the wire carries with no request id. They are their own case
    /// because the id is what separates them, and a shape that gave every frame an id
    /// would have to invent one here - which is what the spike did, answering 0 and
    /// leaving every reader to know by folklore that 0 meant absent rather than a frame
    /// numbered zero. [LAW:types-are-the-program]
    case control(Kind, payload: [UInt8])
    case request(id: UInt64, payload: [UInt8])
    case response(id: UInt64, payload: [UInt8])

    /// Type bytes 0 through 3, the ones that carry no id. Request is 4 and response is 5;
    /// they are named below rather than here, so this type cannot describe a frame that
    /// has an id.
    enum Kind: UInt8 {
        case heartbeat = 0
        case userData = 1
        case healthCheck = 2
        case healthCheckResponse = 3
    }

    static let requestByte: UInt8 = 4
    static let responseByte: UInt8 = 5

    /// The largest frame this side will allocate for. A keyboard report is 67 bytes and
    /// the framing around it nine more; every response the daemon sends is shorter. The
    /// cap is generous by two orders of magnitude and still refuses the four-gigabyte
    /// allocation a desynced or corrupted header can otherwise ask for, which would end
    /// the process rather than name what arrived.
    static let largestBody = 4096

    var bytes: [UInt8] {
        let body = switch self {
        case .control(let kind, let payload): [kind.rawValue] + payload
        case .request(let id, let payload): [Self.requestByte] + Self.bigEndian(id, bytes: 8) + payload
        case .response(let id, let payload): [Self.responseByte] + Self.bigEndian(id, bytes: 8) + payload
        }
        precondition(body.count <= Self.largestBody, "a frame of \(body.count) bytes, past the \(Self.largestBody) this side reads back")
        return Self.bigEndian(UInt64(body.count), bytes: 4) + body
    }

    /// [LAW:parse-dont-validate] The length is sane by the time it leaves here, so
    /// nothing downstream allocates against a number it has to think about first.
    static func bodyLength(header: [UInt8]) throws -> Int {
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length >= 1 else { throw DaemonError.malformed("an empty frame") }
        guard length <= largestBody else { throw DaemonError.malformed("a frame of \(length) bytes, past the \(largestBody) this reads") }
        return length
    }

    static func decode(body: [UInt8]) throws -> Frame {
        guard let type = body.first else { throw DaemonError.malformed("a frame body of no bytes, which has no type") }
        switch type {
        case requestByte, responseByte:
            guard body.count >= 9 else { throw DaemonError.malformed("a frame of \(body.count) bytes, too short for the id its type promises") }
            let id = body[1..<9].reduce(0) { $0 << 8 | UInt64($1) }
            let payload = Array(body[9...])
            return type == requestByte ? .request(id: id, payload: payload) : .response(id: id, payload: payload)
        default:
            guard let kind = Kind(rawValue: type) else { throw DaemonError.malformed("frame type \(type), which this was not written for") }
            return .control(kind, payload: Array(body[1...]))
        }
    }

    private static func bigEndian(_ value: UInt64, bytes: Int) -> [UInt8] {
        (0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }
}
