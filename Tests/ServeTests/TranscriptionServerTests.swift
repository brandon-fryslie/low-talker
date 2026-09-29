import Foundation
import LowTalkerCore
import Network
@testable import Serve
import Synchronization
import Testing

/// An engine that hears the conformance fixture's words in whatever it is given, and keeps
/// what it was given.
private final class Stub: Transcriber {
    let heard = Mutex<[(seconds: TimeInterval, vocabulary: Vocabulary)]>([])
    let answer: Result<Transcript, any Error>

    init(_ answer: Result<Transcript, any Error> = .success(Transcript(typed: " Hello world, this is LowTalker."))) {
        self.answer = answer
    }

    func transcribe(
        _ audio: some AsyncSequence<AudioClip, Never> & Sendable,
        expecting vocabulary: Vocabulary,
        partial: @escaping @Sendable (Partial) -> Void
    ) async throws -> Transcript {
        let seconds = await audio.reduce(0) { $0 + $1.duration }
        heard.withLock { $0.append((seconds, vocabulary)) }
        return try answer.get()
    }
}

private struct StubFailure: Error, CustomStringConvertible {
    var description: String { "the stub engine was told to fail" }
}

/// A server on a loopback port the system chose, and every event it records.
private struct Running {
    let server: TranscriptionServer
    let events: AsyncStream<ServedRequest>

    static func start(_ engine: ServedEngine) async throws -> Running {
        let (events, sink) = AsyncStream<ServedRequest>.makeStream()
        let server = try await TranscriptionServer.listen(on: .ipv4(.loopback), port: .any, engine: { engine }, record: { sink.yield($0) })
        return Running(server: server, events: events)
    }

    var base: String { "http://127.0.0.1:\(server.port.rawValue)/v1" }

    func post(_ fields: [(name: String, filename: String?, value: Data)], path: String = "audio/transcriptions") async throws -> (HTTPURLResponse, Data) {
        let boundary = UUID().uuidString
        var body = Data()
        for field in fields {
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field.name)\"".utf8)
            body += Data((field.filename.map { "; filename=\"\($0)\"" } ?? "").utf8) + Data("\r\n\r\n".utf8)
            body += field.value + Data("\r\n".utf8)
        }
        body += Data("--\(boundary)--\r\n".utf8)
        return try await post(body, boundary: boundary, path: path)
    }

    func post(_ body: Data, boundary: String = "b", path: String = "audio/transcriptions") async throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: URL(string: "\(base)/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        return (response as! HTTPURLResponse, data)
    }

    func nextEvent() async throws -> ServedRequest {
        var iterator = events.makeAsyncIterator()
        return try #require(await iterator.next())
    }
}

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")))
}

private func error(_ body: Data) throws -> [String: Any] {
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    return try #require(object["error"] as? [String: Any])
}

@Suite struct TranscriptionServerTests {
    /// The contract, judged by the suite that judges every server (low-serve-axq.50m): its
    /// REST checks, sent as Pipecat sends them, all pass over an engine that hears the
    /// fixture. The Realtime checks are another endpoint's.
    @Test func passesTheConformanceSuitesRESTChecks() async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let suite = Process()
        suite.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        suite.arguments = ["python3", repository.appendingPathComponent("scripts/conformance").path, "check", running.base]
        let output = Pipe()
        suite.standardOutput = output
        try suite.run()
        // Read and waited on off the cooperative pool, which the server answering the
        // suite runs on.
        let printed = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                suite.waitUntilExit()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
        let summary = try #require(printed.split(separator: "\n").last.map { Data($0.utf8) })
        let results = try #require((JSONSerialization.jsonObject(with: summary) as? [String: Any])?["results"] as? [[String: Any]])
        let rest = results.filter { ($0["check"] as? String)?.hasPrefix("rest ") == true }
        #expect(rest.count == 7, "\(printed)")
        for result in rest {
            #expect(["pass", "skip"].contains(result["outcome"] as? String), "\(result)")
        }
    }

    /// An mp3 is decoded as a wav is, and the engine hears all of it.
    @Test func hearsAnMP3() async throws {
        let stub = Stub()
        let running = try await Running.start(.ready(stub))
        defer { running.server.stop() }
        let (response, body) = try await running.post([("model", nil, Data("gpt-transcribe".utf8)), ("file", "audio.mp3", fixture("hello-16k-mono.mp3"))])
        #expect(response.statusCode == 200)
        #expect(try JSONSerialization.jsonObject(with: body) as? [String: AnyHashable] == [
            "text": "Hello world, this is LowTalker.", "usage": ["type": "duration", "seconds": 3] as [String: AnyHashable],
        ])
        let seconds = try #require(stub.heard.withLock { $0.first?.seconds })
        #expect(seconds > 2.2 && seconds < 2.6)
        let event = try await running.nextEvent()
        #expect(event.status == 200 && event.words == 5 && event.model == "gpt-transcribe" && event.error == nil)
    }

    /// The prompt is the vocabulary a dictation mode would give: one term, as written.
    @Test func promptIsTheVocabulary() async throws {
        let stub = Stub()
        let running = try await Running.start(.ready(stub))
        defer { running.server.stop() }
        let (response, _) = try await running.post([
            ("model", nil, Data("m".utf8)), ("prompt", nil, Data(" LowTalker ".utf8)), ("file", "audio.mp3", fixture("hello-16k-mono.mp3")),
        ])
        #expect(response.statusCode == 200)
        #expect(stub.heard.withLock { $0.first?.vocabulary } == Vocabulary([try Vocabulary.Term("LowTalker")]))
        #expect(try await running.nextEvent().vocabularyTerms == 1)
    }

    /// No words heard in real audio is an empty transcript, not a failure.
    @Test func realAudioWithNoWordsIsAnEmptyTranscript() async throws {
        let running = try await Running.start(.ready(Stub(.success(Transcript(words: [])))))
        defer { running.server.stop() }
        let (response, body) = try await running.post([
            ("model", nil, Data("m".utf8)), ("response_format", nil, Data("text".utf8)), ("file", "audio.mp3", fixture("hello-16k-mono.mp3")),
        ])
        #expect(response.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self) == "\n")
    }

    /// Refused before the upload is read: a file that is not audio still hears 503.
    @Test func aRequestBeforeTheModelIsResidentIs503() async throws {
        let running = try await Running.start(.notResident("still loading"))
        defer { running.server.stop() }
        let (response, body) = try await running.post([("model", nil, Data("m".utf8)), ("file", "audio.wav", Data("not audio".utf8))])
        #expect(response.statusCode == 503)
        #expect(try error(body)["code"] as? String == "model_not_ready")
        #expect(try (error(body)["message"] as? String)?.contains("still loading") == true)
        let event = try await running.nextEvent()
        #expect(event.error == "model_not_ready" && event.audioSeconds == nil)
    }

    /// A prompt the engine cannot take is the client's to fix, so it is a 400 naming it.
    @Test func aPromptTheEngineRefusesIs400() async throws {
        let running = try await Running.start(.ready(Stub(.failure(VocabularyError.tooLong(tokens: 300, limit: 224)))))
        defer { running.server.stop() }
        let (response, body) = try await running.post([
            ("model", nil, Data("m".utf8)), ("prompt", nil, Data("a long paragraph".utf8)), ("file", "audio.mp3", fixture("hello-16k-mono.mp3")),
        ])
        #expect(response.statusCode == 400)
        #expect(try error(body)["param"] as? String == "prompt")
        #expect(try error(body)["type"] as? String == "invalid_request_error")
    }

    /// A refusal made before the body is read still reaches a client that is sending one
    /// larger than the socket holds, and the drain is recorded. How much of the body the
    /// client goes on sending once it hears the refusal is the client's choice.
    @Test func aRefusedBodyIsDrainedSoTheClientHearsTheRefusal() async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        let oversize = TranscriptionServer.bodyLimit + 1024 * 1024
        let (response, body) = try await running.post(Data(count: oversize))
        #expect(response.statusCode == 413)
        #expect(try error(body)["code"] as? String == "request_too_large")
        let event = try await running.nextEvent()
        #expect(event.status == 413 && event.unread != nil && event.lost == nil)
    }

    /// A client that closes before its request is whole is recorded as lost, unanswered.
    @Test func aConnectionClosedMidRequestIsLost() async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        let connection = NWConnection(host: .ipv4(.loopback), port: running.server.port, using: .tcp)
        connection.start(queue: DispatchQueue(label: "test.client"))
        connection.send(content: Data("POST /v1/audio/transcriptions HTTP/1.1\r\n".utf8), contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        defer { connection.cancel() }
        let event = try await running.nextEvent()
        #expect(event.status == nil && event.lost != nil)
    }

    /// A client that expects to be told to go on hears 100 Continue before it sends a byte
    /// of body, then the answer.
    @Test func aClientExpectingContinueIsToldToSendTheBody() async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        let connection = NWConnection(host: .ipv4(.loopback), port: running.server.port, using: .tcp)
        connection.start(queue: DispatchQueue(label: "test.client"))
        defer { connection.cancel() }
        let body = Data("--b\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nm\r\n--b--\r\n".utf8)
        let head = "POST /v1/audio/transcriptions HTTP/1.1\r\ncontent-type: multipart/form-data; boundary=b\r\ncontent-length: \(body.count)\r\nexpect: 100-continue\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .idempotent)
        #expect(try await connection.received() == "HTTP/1.1 100 Continue\r\n\r\n")
        connection.send(content: body, completion: .idempotent)
        #expect(try await connection.received().hasPrefix("HTTP/1.1 400 "))
    }

    @Test func stoppingEndsTheServer() async throws {
        let running = try await Running.start(.ready(Stub()))
        running.server.stop()
        try await running.server.finished()
    }

    @Test func anEngineFailureIs500WithTheReason() async throws {
        let running = try await Running.start(.ready(Stub(.failure(StubFailure()))))
        defer { running.server.stop() }
        let (response, body) = try await running.post([("model", nil, Data("m".utf8)), ("file", "audio.mp3", fixture("hello-16k-mono.mp3"))])
        #expect(response.statusCode == 500)
        #expect(try (error(body)["message"] as? String)?.contains("the stub engine was told to fail") == true)
    }

    /// Refusals the conformance suite does not send, each in OpenAI's error shape and each
    /// naming what it refused.
    @Test(arguments: [
        ([("file", "audio.wav", "RIFF")], 400, "missing_required_parameter", "model"),
        ([("model", nil, "m"), ("model", nil, "m"), ("file", "audio.wav", "RIFF")], 400, "repeated_parameter", "model"),
        ([("model", nil, "m"), ("stream", nil, "true"), ("file", "audio.wav", "RIFF")], 400, "unsupported_parameter", "stream"),
        ([("model", nil, "m"), ("file", "audio.wav", "not audio at all")], 400, "invalid_audio", "file"),
        ([("model", nil, "m"), ("language", nil, "fr"), ("file", "audio.wav", "RIFF")], 400, "unsupported_value", "language"),
    ] as [([(String, String?, String)], Int, String, String)])
    func refusesAndSaysWhat(fields: [(String, String?, String)], status: Int, code: String, param: String) async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        let (response, body) = try await running.post(fields.map { ($0.0, $0.1, Data($0.2.utf8)) })
        #expect(response.statusCode == status)
        #expect(try error(body)["code"] as? String == code)
        #expect(try error(body)["param"] as? String == param)
        // The server's own temporary files are not the client's business.
        #expect(try (error(body)["message"] as? String)?.contains("lowtalker-upload-") == false)
    }

    @Test func anotherPathIs404() async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        let (response, body) = try await running.post([], path: "audio/translations")
        #expect(response.statusCode == 404)
        #expect(try error(body)["code"] as? String == "unknown_url")
        let event = try await running.nextEvent()
        #expect(event.path == "/v1/audio/translations" && event.status == 404 && event.bytes == nil)
    }
}

@Suite struct FormFieldTests {
    @Test func readsFieldsAroundAPreambleUnderAQuotedBoundary() throws {
        let body = Data("preamble\r\n--b\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nm\r\n--b\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n\r\nx\r\n--b--\r\n".utf8)
        #expect(try FormField.parse(body, contentType: "multipart/form-data; boundary=\"b\"") == [
            FormField(name: "model", filename: nil, value: Data("m".utf8)),
            FormField(name: "file", filename: "a.wav", value: Data("\r\nx".utf8)),
        ])
    }

    /// Two lengths for one body are no length: the request is refused, not read by one.
    @Test func twoContentLengthsAreMalformed() throws {
        let head = try RequestHead.parse(Data("POST / HTTP/1.1\r\ncontent-length: 5\r\nContent-Length: 6".utf8))
        #expect(throws: APIError.malformed("content-length \"5, 6\" is not a byte count")) {
            try head.bodyLength(limit: 100)
        }
    }

    @Test func aSemicolonInsideAQuotedFilenameIsPartOfIt() {
        #expect(FormField.parameter("filename", in: "form-data; name=\"file\"; filename=\"take;1.mp3\"") == "take;1.mp3")
    }

    @Test func aBodyWithNoClosingBoundaryIsMalformed() {
        let body = Data("--b\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nm\r\n".utf8)
        #expect(throws: APIError.malformed("the multipart body has no closing boundary")) {
            try FormField.parse(body, contentType: "multipart/form-data; boundary=b")
        }
    }
}

extension NWConnection {
    /// The next bytes the server sent, as text.
    fileprivate func received() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: String(decoding: data ?? Data(), as: UTF8.self)) }
            }
        }
    }
}
