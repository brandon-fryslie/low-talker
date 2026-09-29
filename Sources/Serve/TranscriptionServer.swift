import Foundation
import LowTalkerCore
import Network
import os
import Synchronization

/// What answers a transcription when one is asked for: the resident engine, or the reason
/// there is none yet. The server asks at each request, so a host whose model is still
/// loading can listen from launch and answer 503 until it is ready.
public enum ServedEngine: Sendable {
    case ready(any Transcriber)
    case notResident(String)
}

/// OpenAI's `POST /v1/audio/transcriptions` over any `Transcriber`, on one TCP listener
/// (epic low-serve-axq). It knows nothing of who hosts it or who calls it.
///
/// [LAW:no-ambient-temporal-coupling] A server in hand is listening: `listen` returns only
/// once the port is bound, so there is no server to call too early and no start to forget.
public final class TranscriptionServer: Sendable {
    /// The port bound, which is the one asked for or, for port 0, the one the system chose.
    public let port: NWEndpoint.Port
    private let listener: NWListener

    /// OpenAI's limit on an uploaded file is 25 MB; the rest is the form around it.
    static let bodyLimit = 26 * 1024 * 1024
    /// How long a client has to send its whole request before the connection is dropped.
    static let readDeadline: DispatchTimeInterval = .seconds(120)

    private init(port: NWEndpoint.Port, listener: NWListener) {
        self.port = port
        self.listener = listener
    }

    /// Listens on `host` and `port` until `stop`, answering every request with what `engine`
    /// says at that moment and handing one `ServedRequest` per connection to `record`.
    public static func listen(
        on host: NWEndpoint.Host,
        port: NWEndpoint.Port,
        engine: @escaping @Sendable () -> ServedEngine,
        record: @escaping @Sendable (ServedRequest) -> Void = ServedRequest.log
    ) async throws -> TranscriptionServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "lowtalker.serve")
        let answering = Answering(engine: engine, record: record, queue: queue)
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Task { await answering.serve(connection) }
        }
        let bound = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint.Port, any Error>) in
            // The state handler runs for every change; only the first ready or failure
            // decides the listen, and a failure after it is the log's to tell.
            let waiting = Mutex<CheckedContinuation<NWEndpoint.Port, any Error>?>(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    waiting.withLock { $0.take() }?.resume(returning: listener.port!)
                case .failed(let error):
                    guard let continuation = waiting.withLock({ $0.take() }) else {
                        return ServedRequest.logger.error("listener failed: \(error, privacy: .public)")
                    }
                    listener.cancel()
                    continuation.resume(throwing: error)
                case .setup, .waiting, .cancelled:
                    break
                @unknown default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return TranscriptionServer(port: bound, listener: listener)
    }

    /// Stops accepting connections. A request already being answered is answered.
    public func stop() {
        listener.cancel()
    }
}

/// One request's answer, from the first byte read to the connection's close.
private struct Answering: Sendable {
    let engine: @Sendable () -> ServedEngine
    let record: @Sendable (ServedRequest) -> Void
    let queue: DispatchQueue

    func serve(_ connection: NWConnection) async {
        let clock = ContinuousClock()
        let started = clock.now
        var event = ServedRequest()
        // [LAW:no-ambient-temporal-coupling] The deadline is the connection's own: a client
        // that stops sending is cut off, which fails the pending read.
        let deadline = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + TranscriptionServer.readDeadline, execute: deadline)
        do {
            let response = try await respond(connection, readDeadline: deadline, &event)
            event.status = response.status.rawValue
            try await connection.sendAll(response.wire)
        } catch {
            event.lost = "\(error)"
        }
        deadline.cancel()
        connection.cancel()
        event.durationMs = Int((clock.now - started) / .milliseconds(1))
        record(event)
    }

    /// The answer to the request `connection` carries. Every refusal is an answer in
    /// OpenAI's error shape; only a connection that fails before it can be answered throws.
    private func respond(_ connection: NWConnection, readDeadline: DispatchWorkItem, _ event: inout ServedRequest) async throws -> HTTPResponse {
        var reader = Reader(connection: connection, cancelOnRead: readDeadline)
        do {
            let head = try await reader.head()
            event.method = head.method
            event.path = head.path
            guard head.method == "POST", head.path == "/v1/audio/transcriptions" else {
                throw APIError.notFound(method: head.method, path: head.path)
            }
            let body = try await reader.body(count: head.bodyLength(limit: TranscriptionServer.bodyLimit))
            event.bytes = body.count
            let request = try TranscriptionRequest.parse(FormField.parse(body, contentType: head.headers["content-type"]))
            event.model = request.model
            event.language = request.language
            event.format = request.format.rawValue
            event.vocabularyTerms = request.vocabulary.terms.count
            let clip = try request.upload.clip()
            event.audioSeconds = clip.duration
            let transcriber: any Transcriber
            switch engine() {
            case .ready(let resident): transcriber = resident
            case .notResident(let reason): throw APIError.notResident(reason)
            }
            let transcript: Transcript
            do {
                transcript = try await transcriber.transcribe(clip, expecting: request.vocabulary)
            } catch {
                throw APIError.engineFailed("\(error)")
            }
            event.words = transcript.words.count
            return request.format.response(transcript, heard: clip)
        } catch let refusal as APIError {
            event.error = refusal.code
            return refusal.response
        }
    }
}

/// A connection's bytes, taken as the request needs them.
private struct Reader {
    let connection: NWConnection
    /// Disarmed once the whole request is in: the deadline covers reading, not answering.
    let cancelOnRead: DispatchWorkItem
    var buffer = Data()

    static let headLimit = 64 * 1024
    private static let endOfHead = Data("\r\n\r\n".utf8)

    mutating func head() async throws -> RequestHead {
        while true {
            if let end = buffer.firstRange(of: Self.endOfHead) {
                let head = try RequestHead.parse(Data(buffer[..<end.lowerBound]))
                buffer = Data(buffer[end.upperBound...])
                return head
            }
            guard buffer.count < Self.headLimit else { throw APIError.malformed("the request head is over \(Self.headLimit) bytes") }
            buffer += try await more()
        }
    }

    mutating func body(count: Int) async throws -> Data {
        while buffer.count < count {
            buffer += try await more()
        }
        cancelOnRead.cancel()
        return Data(buffer.prefix(count))
    }

    private func more() async throws -> Data {
        guard let chunk = try await connection.receiveChunk() else { throw ConnectionClosed() }
        return chunk
    }
}

private struct ConnectionClosed: Error, CustomStringConvertible {
    var description: String { "the client closed the connection before its request was whole" }
}

extension NWConnection {
    /// The next bytes the peer sent, or nil once it has closed its side.
    fileprivate func receiveChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    // At least one byte was asked for, so no data is the end of the stream.
                    continuation.resume(returning: data.flatMap { $0.isEmpty ? nil : $0 })
                }
            }
        }
    }

    fileprivate func sendAll(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

/// Everything known about one connection's request once it has been answered or lost: the
/// server's one event per unit of work. [LAW:nothing-unseen] A field is nil when the request
/// failed before it could be known, so how far a request got is read off which are set.
public struct ServedRequest: Sendable, Codable, Equatable {
    public internal(set) var method: String?
    public internal(set) var path: String?
    /// The status answered; nil when the connection was lost first.
    public internal(set) var status: Int?
    /// The OpenAI error code of a refusal.
    public internal(set) var error: String?
    /// Why the connection failed before it could be answered.
    public internal(set) var lost: String?
    public internal(set) var bytes: Int?
    public internal(set) var model: String?
    public internal(set) var language: String?
    public internal(set) var format: String?
    public internal(set) var vocabularyTerms: Int?
    public internal(set) var audioSeconds: Double?
    public internal(set) var words: Int?
    public internal(set) var durationMs = 0

    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "lowtalker", category: "serve")

    /// The event as one line of JSON.
    public var json: String {
        String(decoding: JSONEncoder.served.encodeAlways(self), as: UTF8.self)
    }

    /// The event in the unified log.
    public static let log: @Sendable (ServedRequest) -> Void = { event in
        logger.info("\(event.json, privacy: .public)")
    }
}
