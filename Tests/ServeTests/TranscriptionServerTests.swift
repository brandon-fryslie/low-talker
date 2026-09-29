import Flavors
import Foundation
import LowTalkerCore
import Network
@testable import Serve
import Synchronization
import Testing

@Suite struct TranscriptionServerTests {
    /// A second server on an address already served is refused, naming the installation and
    /// the address: two copies of one flavor read as that, not as a bare socket error.
    @Test func aServedAddressIsRefusedByName() async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        let taken = ListenAddress(flavor: .release, port: running.server.port)
        await #expect {
            try await TranscriptionServer.listen(at: taken, engine: { .ready(Stub()) }, record: { _ in }).stop()
        } throws: { error in
            "\(error)".hasPrefix("LowTalker (release) cannot serve on 127.0.0.1:\(running.server.port): ")
                && "\(error)".contains("Address already in use")
        }
    }

    /// An installation serves on loopback at its own port unless told otherwise.
    @Test(arguments: Flavor.allCases)
    func anInstallationServesOnLoopbackAtItsPort(flavor: Flavor) {
        #expect("\(ListenAddress(flavor: flavor))" == "127.0.0.1:\(flavor.serverPort)")
    }

    /// The contract, judged by the suite that judges every server (low-serve-axq.50m): its
    /// REST and Realtime checks, sent as Pipecat sends them, all pass over an engine that
    /// hears the fixture and confirms words while the audio streams. The token checks skip,
    /// since this server requires none.
    @Test func passesTheConformanceSuite() async throws {
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
        #expect(results.count == 10, "\(printed)")
        for result in results {
            #expect(["pass", "skip"].contains(result["outcome"] as? String), "\(result)")
        }
        #expect(results.filter { $0["outcome"] as? String == "skip" }.count == 3, "\(printed)")
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

    /// A prompt with no word in it is ordinary speech: no vocabulary, and no refusal.
    @Test func aWordlessPromptIsNoVocabulary() async throws {
        let stub = Stub()
        let running = try await Running.start(.ready(stub))
        defer { running.server.stop() }
        let (response, _) = try await running.post([
            ("model", nil, Data("m".utf8)), ("prompt", nil, Data(" ... ".utf8)), ("file", "audio.mp3", fixture("hello-16k-mono.mp3")),
        ])
        #expect(response.statusCode == 200)
        #expect(stub.heard.withLock { $0.first?.vocabulary } == Vocabulary([]))
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
