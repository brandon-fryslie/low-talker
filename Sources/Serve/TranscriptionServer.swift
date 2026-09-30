import Flavors
import Foundation
import LowTalkerCore
import Network
import os
import Synchronization

/// What answers a transcription when one is asked for: the resident engine, the reason
/// there is none yet, or why there will be none. The server asks at each request, so a host whose model is still
/// loading can listen from launch and answer 503 until it is ready.
public enum ServedEngine: Sendable {
    case ready(any Transcriber)
    case notResident(String)
    /// Will not be resident: the model could not be loaded, so waiting will not help.
    case failed(String)
}

/// OpenAI's `POST /v1/audio/transcriptions` and its Realtime transcription socket,
/// `GET /v1/realtime?intent=transcription`, over any `Transcriber`, on one TCP listener
/// (epic low-serve-axq). It knows nothing of who hosts it or who calls it.
///
/// [LAW:no-ambient-temporal-coupling] A server in hand is listening: `listen` returns only
/// once the port is bound, so there is no server to call too early and no start to forget.
public final class TranscriptionServer: Sendable {
    /// The address bound, the one every rendering of where this server is derives from.
    /// [LAW:one-source-of-truth]
    let address: ListenAddress
    public var port: NWEndpoint.Port { address.port }
    /// What a client is given: the root both OpenAI routes are served under.
    public var baseURL: String { "http://\(address)/v1" }
    private let listener: NWListener
    /// A task of its own, so a caller cancelled while it waits still learns when the port is
    /// let go rather than returning before it is.
    private let ended: Task<Void, any Error>

    /// OpenAI's limit on an uploaded file is 25 MB; the rest is the form around it.
    static let bodyLimit = 26 * 1024 * 1024
    /// How long a client has to send its whole request, and then to close its side once
    /// answered, before the connection is dropped.
    static let readDeadline: DispatchTimeInterval = .seconds(120)

    private init(address: ListenAddress, listener: NWListener, ended: Task<Void, any Error>) {
        self.address = address
        self.listener = listener
        self.ended = ended
    }

    /// Listens on `flavor`'s port where `binding` says until `stop`, answering every request
    /// `binding` admits with what `engine` says at that moment and handing one
    /// `ServedRequest` per connection to `record`. Throws `ListenRefused` when the address
    /// cannot be had, which is most often another process of the same installation already
    /// serving on it. Cancelled while the address is not yet had, as while no interface holds
    /// it, the listen lets it go and throws.
    public static func listen(
        for flavor: Flavor,
        on binding: ServeBinding,
        engine: @escaping @Sendable () -> ServedEngine,
        record: @escaping @Sendable (ServedRequest) -> Void = ServedRequest.log
    ) async throws(ListenRefused) -> TranscriptionServer {
        try await listen(at: ListenAddress(flavor: flavor, binding: binding), engine: engine, record: record)
    }

    static func listen(
        at address: ListenAddress,
        engine: @escaping @Sendable () -> ServedEngine,
        record: @escaping @Sendable (ServedRequest) -> Void
    ) async throws(ListenRefused) -> TranscriptionServer {
        let server: TranscriptionServer
        do {
            server = try await bind(address, engine: engine, record: record)
        } catch {
            throw ListenRefused(address: address, reason: error)
        }
        ServedRequest.logger.notice("\(address.flavor, privacy: .public) serving on \(server.address, privacy: .public), \(address.binding, privacy: .public)")
        return server
    }

    private static func bind(
        _ address: ListenAddress,
        engine: @escaping @Sendable () -> ServedEngine,
        record: @escaping @Sendable (ServedRequest) -> Void
    ) async throws -> TranscriptionServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: address.host, port: address.port)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "lowtalker.serve")
        let answering = Answering(binding: address.binding, engine: engine, record: record, queue: queue)
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Task { await answering.serve(connection) }
        }
        let (ended, end) = AsyncThrowingStream<Never, any Error>.makeStream()
        let bound = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint.Port, any Error>) in
                // The state handler runs for every change; the first ready, failure or cancel
                // decides the listen, and one after it ends the server, which `finished` tells.
                let waiting = Mutex<CheckedContinuation<NWEndpoint.Port, any Error>?>(continuation)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        waiting.withLock { $0.take() }?.resume(returning: listener.port!)
                    case .failed(let error):
                        ServedRequest.logger.error("listener failed: \(error, privacy: .public)")
                        listener.cancel()
                        waiting.withLock { $0.take() }?.resume(throwing: error)
                        end.finish(throwing: error)
                    case .cancelled:
                        waiting.withLock { $0.take() }?.resume(throwing: CancellationError())
                        end.finish()
                    case .waiting(let error):
                        // An address no interface holds yet waits for one to, and says so.
                        ServedRequest.logger.notice("listener waiting: \(error, privacy: .public)")
                    case .setup:
                        break
                    @unknown default:
                        break
                    }
                }
                listener.start(queue: queue)
            }
        } onCancel: {
            listener.cancel()
        }
        return TranscriptionServer(
            address: ListenAddress(flavor: address.flavor, binding: address.binding, port: bound),
            listener: listener,
            ended: Task { for try await _ in ended {} }
        )
    }

    /// Stops accepting connections. A request already being answered is answered.
    public func stop() {
        listener.cancel()
    }

    /// Returns once the server has stopped, and throws the failure that stopped it if it
    /// was not `stop`.
    public func finished() async throws {
        try await ended.value
    }
}

/// Where a server listens, and for which installation: the installation is part of the
/// address because it is what a person reading a refusal needs to know. The port alone does
/// not say whose it is.
struct ListenAddress: Sendable, CustomStringConvertible {
    let flavor: Flavor
    /// [LAW:one-source-of-truth] The host is read off the binding, so the interface a server
    /// listens on and the token it requires there cannot be two facts that disagree.
    let binding: ServeBinding
    let port: NWEndpoint.Port

    init(flavor: Flavor, binding: ServeBinding = .loopback, port: NWEndpoint.Port? = nil) {
        self.flavor = flavor
        self.binding = binding
        self.port = port ?? NWEndpoint.Port(rawValue: flavor.serverPort)!
    }

    var host: NWEndpoint.Host {
        switch binding {
        case .loopback: .ipv4(.loopback)
        case .interface(let address, _): NWEndpoint.Host(address.literal)
        }
    }

    /// Host and port as a URL writes them, an IPv6 host in brackets.
    var description: String {
        switch binding {
        case .interface(let address, _) where address.isIPv6: "[\(address)]:\(port)"
        case .loopback, .interface: "\(host):\(port)"
        }
    }
}

/// A server that could not start listening, naming the installation and the address.
/// [LAW:no-silent-failure] A second process binding one flavor's port is the case this
/// exists for: without the names, it reads as a network error and not as two copies.
public struct ListenRefused: Error, CustomStringConvertible {
    let address: ListenAddress
    let reason: any Error

    public var description: String {
        "\(address.flavor.displayName) (\(address.flavor)) cannot serve on \(address): \(reason)"
    }
}

/// One request's answer, from the first byte read to the connection's close.
private struct Answering: Sendable {
    let binding: ServeBinding
    let engine: @Sendable () -> ServedEngine
    let record: @Sendable (ServedRequest) -> Void
    let queue: DispatchQueue

    func serve(_ connection: NWConnection) async {
        let clock = ContinuousClock()
        let started = clock.now
        var event = ServedRequest()
        let deadline = cutOff(connection)
        var reader = Reader(connection: connection, cancelOnRead: deadline)
        // What holds did to this request's decodes, counted by the engine's owner as it
        // decides them.
        let ledger = EngineTurns.Ledger()
        await EngineTurns.$ledger.withValue(ledger) { do {
            switch try await respond(connection, &reader, &event) {
            case .http(let response):
                event.status = response.status.rawValue
                try await connection.sendFinal(response.wire)
                // Closing a socket that still holds a request's unread bytes resets it, and a
                // client still sending its body then loses the answer as well. So the answer
                // closes the server's side alone, and what the client sends until it closes
                // its own is read and dropped.
                let lingering = cutOff(connection)
                event.unread = await connection.drain()
                lingering.cancel()
            case .refusedSocket(let handshake, let refusal):
                // Upgraded, told why in an error event, and closed 3000, as OpenAI answers a
                // socket opened with a key it does not know; what the client sends after is
                // its close, read and dropped.
                deadline.cancel()
                event.status = 101
                event.error = refusal.code
                try await connection.sendFinal(handshake + WebSocket.frame(.text, ServerEvent.error(refusal, clientEvent: nil).json) + WebSocket.close(3000))
                let lingering = cutOff(connection)
                event.unread = await connection.drain()
                lingering.cancel()
            case .realtime(let handshake, let socket):
                // A socket is open as long as the client keeps it: the read deadline is the
                // request's, and the request is whole.
                deadline.cancel()
                try await connection.send(handshake)
                event.status = 101
                (event.realtime, event.lost) = await socket.run(connection, &reader)
            }
        } catch {
            event.lost = "\(error)"
        } }
        event.turns = ledger.tally
        deadline.cancel()
        connection.cancel()
        event.durationMs = Int((clock.now - started) / .milliseconds(1))
        record(event)
    }

    /// [LAW:no-ambient-temporal-coupling] The deadline is the connection's own: a client
    /// that stops sending is cut off, which fails the pending read.
    private func cutOff(_ connection: NWConnection) -> DispatchWorkItem {
        let deadline = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + TranscriptionServer.readDeadline, execute: deadline)
        return deadline
    }

    /// What a request is answered with: a response, or the websocket it upgrades to.
    private enum Answer {
        case http(HTTPResponse)
        case realtime(handshake: Data, RealtimeSocket)
        /// The upgrade, followed at once by the error that ends the socket.
        case refusedSocket(handshake: Data, RealtimeError)
    }

    /// The answer to the request `reader` reads. Every refusal is an answer in OpenAI's
    /// error shape; only a connection that fails before it can be answered throws.
    private func respond(_ connection: NWConnection, _ reader: inout Reader, _ event: inout ServedRequest) async throws -> Answer {
        do {
            let head = try await reader.head()
            event.method = head.method
            event.path = head.path
            // [LAW:single-enforcer] Asked once, before any route: a caller the binding does
            // not admit reaches nothing, and learns only that its key is wrong.
            guard binding.admits(authorization: head.headers["authorization"]) else { return try refusal(head) }
            switch head.path {
            case "/v1/realtime":
                return try realtime(head)
            case "/v1/audio/transcriptions" where head.method == "POST":
                return .http(try await transcription(head, connection, &reader, &event))
            default:
                throw APIError.notFound(method: head.method, path: head.path)
            }
        } catch let refusal as APIError {
            event.error = refusal.code
            return .http(refusal.response)
        }
    }

    /// The answer to a caller without the token: a socket upgrade is upgraded and ended as
    /// OpenAI ends a socket opened with a key it does not know, and anything else, a
    /// handshake that is not one included, is a 401. What the request lacks besides the key
    /// is not said, since that would describe the server to a caller it does not answer.
    private func refusal(_ head: RequestHead) throws(APIError) -> Answer {
        guard head.path == "/v1/realtime", let handshake = try? WebSocket.handshake(head) else { throw .invalidAPIKey }
        return .refusedSocket(handshake: handshake, .invalidAPIKey)
    }

    /// The upgrade to a Realtime transcription socket over the engine resident now, which
    /// the socket keeps. Asked before upgrading, so a server still loading refuses with a
    /// status rather than opening a socket it cannot serve.
    private func realtime(_ head: RequestHead) throws(APIError) -> Answer {
        let handshake = try WebSocket.handshake(head)
        guard head.query["intent"] == "transcription" else {
            throw .unsupportedValue(field: "intent", value: head.query["intent"] ?? "(none)", accepted: "transcription")
        }
        switch engine() {
        case .ready(let transcriber): return .realtime(handshake: handshake, RealtimeSocket(transcriber: transcriber))
        case .notResident(let reason): throw .notResident(reason)
        case .failed(let reason): throw .engineFailed(reason)
        }
    }

    private func transcription(_ head: RequestHead, _ connection: NWConnection, _ reader: inout Reader, _ event: inout ServedRequest) async throws -> HTTPResponse {
        let length = try head.bodyLength(limit: TranscriptionServer.bodyLimit)
        // Asked before the body is asked for or read, so a server still loading refuses at once.
        let transcriber: any Transcriber
        switch engine() {
        case .ready(let resident): transcriber = resident
        case .notResident(let reason): throw APIError.notResident(reason)
        case .failed(let reason): throw APIError.engineFailed(reason)
        }
        // A client that asked to hear the request is wanted before sending its body
        // (curl, for any large upload) waits for this, or for a timeout, before it sends.
        if head.headers["expect"]?.lowercased() == "100-continue" {
            try await connection.send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }
        let body = try await reader.body(count: length)
        event.bytes = body.count
        let request = try TranscriptionRequest.parse(FormField.parse(body, contentType: head.headers["content-type"]))
        event.model = request.model
        event.language = request.language?.rawValue
        event.format = request.format.rawValue
        event.vocabularyTerms = request.vocabulary.terms.count
        let clip = try request.upload.clip()
        event.audioSeconds = clip.duration
        let transcript: Transcript
        do {
            transcript = try await transcriber.transcribe(clip, expecting: request.vocabulary)
        } catch let refusal as VocabularyError {
            throw APIError.promptRefused("\(refusal)")
        } catch {
            throw APIError.engineFailed("\(error)")
        }
        event.words = transcript.words.count
        return request.format.response(transcript, heard: clip)
    }
}

/// A connection's bytes, taken as the request needs them.
struct Reader {
    let connection: NWConnection
    /// Disarmed once the whole request is in: the deadline covers reading, not answering.
    let cancelOnRead: DispatchWorkItem
    var buffer = Data()

    static let headLimit = 64 * 1024
    private static let endOfHead = Data("\r\n\r\n".utf8)

    mutating func head() async throws -> RequestHead {
        try await next { buffer in
            guard let end = buffer.firstRange(of: Self.endOfHead) else {
                guard buffer.count < Self.headLimit else { throw APIError.malformed("the request head is over \(Self.headLimit) bytes") }
                return nil
            }
            return (try RequestHead.parse(Data(buffer[..<end.lowerBound])), end.upperBound - buffer.startIndex)
        }
    }

    mutating func body(count: Int) async throws -> Data {
        let body = try await next { buffer in buffer.count < count ? nil : (Data(buffer.prefix(count)), count) }
        cancelOnRead.cancel()
        return body
    }

    /// The first thing `parse` finds in what the client has sent, read for as long as it
    /// finds nothing yet; what it took is gone from the buffer, and what follows it stays.
    mutating func next<T>(_ parse: (Data) throws -> (T, consumed: Int)?) async throws -> T {
        while true {
            if let (value, consumed) = try parse(buffer) {
                buffer = Data(buffer.dropFirst(consumed))
                return value
            }
            guard let chunk = try await connection.receiveChunk() else { throw ConnectionClosed() }
            buffer += chunk
        }
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

    /// Everything the peer sends until it closes its side or the connection fails, counted
    /// and dropped. A failure ends the drain as a close does: the answer is already sent.
    fileprivate func drain() async -> Int {
        var dropped = 0
        while let chunk = try? await receiveChunk() {
            dropped += chunk.count
        }
        return dropped
    }

    /// `data`, and then the end of the server's side of the stream.
    fileprivate func sendFinal(_ data: Data) async throws {
        try await send(data, in: .finalMessage)
    }

    /// `data`, whole: a message sent incomplete is held back until it is completed.
    func send(_ data: Data, in context: ContentContext = .defaultMessage) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
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
    /// Bytes the client sent after it was answered, dropped: a refused request's body.
    public internal(set) var unread: Int?
    public internal(set) var bytes: Int?
    public internal(set) var model: String?
    public internal(set) var language: String?
    public internal(set) var format: String?
    public internal(set) var vocabularyTerms: Int?
    public internal(set) var audioSeconds: Double?
    public internal(set) var words: Int?
    /// What happened on a Realtime socket, for a request that upgraded to one.
    public internal(set) var realtime: RealtimeActivity?
    /// What dictation did to the request: its decodes a hold cancelled and ran again, and
    /// those that waited for a hold.
    public internal(set) var turns = EngineTurns.Tally()
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
