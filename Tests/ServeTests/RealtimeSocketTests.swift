import Foundation
import LowTalkerCore
@testable import Serve
import Testing

/// A Realtime socket to a running server, speaking JSON events.
private struct Client {
    let task: URLSessionWebSocketTask
    /// Every event received so far, in order.
    private(set) var received: [[String: Any]] = []

    init(_ running: Running) {
        task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(running.server.port.rawValue)/v1/realtime?intent=transcription")!)
        task.resume()
    }

    func send(_ event: [String: Any]) async throws {
        try await task.send(.string(String(decoding: JSONSerialization.data(withJSONObject: event), as: UTF8.self)))
    }

    /// Events up to and including the first of `type`.
    mutating func until(_ type: String) async throws -> [String: Any] {
        while true {
            guard case .string(let text) = try await task.receive() else { throw Unexpected.binary }
            let event = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            received.append(event)
            if event["type"] as? String == type { return event }
        }
    }

    func types() -> [String] {
        received.compactMap { $0["type"] as? String }
    }

    /// `seconds` of a 440 Hz tone at 24 kHz, as appends of 100 ms each.
    func append(seconds: Double) async throws {
        let samples = (0..<Int(seconds * 24_000)).map { Int16(8_000 * sin(Double($0) * 2 * .pi * 440 / 24_000)) }
        for chunk in stride(from: 0, to: samples.count, by: 2_400) {
            let bytes = samples[chunk..<min(chunk + 2_400, samples.count)].withUnsafeBytes { Data($0) }
            try await send(["type": "input_audio_buffer.append", "audio": bytes.base64EncodedString()])
        }
    }

    enum Unexpected: Error { case binary }
}

private func update(_ input: [String: Any]) -> [String: Any] {
    ["type": "session.update", "session": ["type": "transcription", "audio": ["input": input]]]
}

@Suite struct RealtimeSocketTests {
    /// Server-side turn detection is refused by name, and the socket stays open: the same
    /// socket then transcribes a turn the client commits.
    @Test func refusesServerVADAndStaysOpen() async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        var client = Client(running)
        _ = try await client.until("session.created")
        try await client.send(update(["turn_detection": ["type": "server_vad"]]))
        let refusal = try await client.until("error")
        let detail = try #require(refusal["error"] as? [String: Any])
        #expect(detail["code"] as? String == "invalid_value")
        #expect(detail["param"] as? String == "session.audio.input.turn_detection")
        try await client.append(seconds: 1)
        try await client.send(["type": "input_audio_buffer.commit"])
        let completed = try await client.until("conversation.item.input_audio_transcription.completed")
        #expect(completed["transcript"] as? String == "Hello world, this is LowTalker.")
        client.task.cancel(with: .normalClosure, reason: nil)
    }

    /// An engine failure fails its item, not the session: no `error` event, which Pipecat
    /// would take as fatal.
    @Test func anEngineFailureFailsTheItemAndNotTheSession() async throws {
        let running = try await Running.start(.ready(Stub(.failure(StubFailure()))))
        defer { running.server.stop() }
        var client = Client(running)
        try await client.append(seconds: 0.5)
        try await client.send(["type": "input_audio_buffer.commit"])
        let failed = try await client.until("conversation.item.input_audio_transcription.failed")
        let detail = try #require(failed["error"] as? [String: Any])
        #expect(detail["type"] as? String == "server_error")
        #expect((detail["message"] as? String)?.contains("the stub engine was told to fail") == true)
        #expect(!client.types().contains("error"))
        client.task.cancel(with: .normalClosure, reason: nil)
    }

    /// The prompt a session is updated with is the vocabulary its next item is heard with,
    /// and the language and model are echoed back.
    @Test func thePromptIsTheItemsVocabulary() async throws {
        let stub = Stub()
        let running = try await Running.start(.ready(stub))
        defer { running.server.stop() }
        var client = Client(running)
        try await client.send(update(["transcription": ["model": "gpt-realtime-whisper", "language": "en", "prompt": "LowTalker"], "turn_detection": NSNull()]))
        let updated = try await client.until("session.updated")
        let echoed = try #require(((updated["session"] as? [String: Any])?["audio"] as? [String: Any])?["input"] as? [String: Any])
        #expect(echoed["transcription"] as? [String: String] == ["model": "gpt-realtime-whisper", "language": "en", "prompt": "LowTalker"])
        try await client.append(seconds: 0.3)
        try await client.send(["type": "input_audio_buffer.commit"])
        _ = try await client.until("conversation.item.input_audio_transcription.completed")
        #expect(stub.heard.withLock { $0.first?.vocabulary } == Vocabulary([try Vocabulary.Term("LowTalker")]))
        client.task.cancel(with: .normalClosure, reason: nil)
    }

    /// An event the server does not know is refused naming its type, and nothing else ends.
    @Test func anUnknownEventIsRefusedByType() async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        var client = Client(running)
        try await client.send(["type": "response.create", "event_id": "event_client_1"])
        let refusal = try #require(try await client.until("error")["error"] as? [String: Any])
        #expect(refusal["param"] as? String == "type")
        #expect(refusal["event_id"] as? String == "event_client_1")
        try await client.send(update([:]))
        _ = try await client.until("session.updated")
        client.task.cancel(with: .normalClosure, reason: nil)
    }

    /// Two turns on one socket are two items, the second following the first.
    @Test func eachCommitIsAnItemFollowingTheLast() async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        var client = Client(running)
        try await client.append(seconds: 0.3)
        try await client.send(["type": "input_audio_buffer.commit"])
        let first = try await client.until("input_audio_buffer.committed")
        _ = try await client.until("conversation.item.input_audio_transcription.completed")
        try await client.append(seconds: 0.3)
        try await client.send(["type": "input_audio_buffer.commit"])
        let second = try await client.until("input_audio_buffer.committed")
        #expect(first["previous_item_id"] is NSNull)
        #expect(second["previous_item_id"] as? String == first["item_id"] as? String)
        #expect(second["item_id"] as? String != first["item_id"] as? String)
        client.task.cancel(with: .normalClosure, reason: nil)
    }

    /// The socket's one event says what happened on it.
    @Test func theSocketsEventCountsWhatHappenedOnIt() async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        var client = Client(running)
        try await client.append(seconds: 1)
        try await client.send(["type": "input_audio_buffer.commit"])
        _ = try await client.until("conversation.item.input_audio_transcription.completed")
        try await client.send(["type": "input_audio_buffer.commit"])
        _ = try await client.until("error")
        client.task.cancel(with: .normalClosure, reason: nil)
        let event = try await running.nextEvent()
        let realtime = try #require(event.realtime)
        #expect(event.status == 101 && event.path == "/v1/realtime" && event.lost == nil)
        #expect(realtime.appends == 10 && realtime.items == 1 && realtime.closeCode == 1000)
        #expect(abs(realtime.audioSeconds - 1) < 0.01)
        #expect(realtime.sent.completed == 1 && realtime.sent.errors == 1 && realtime.sent.deltas >= 2)
    }

    /// Refused before the upgrade, with a status: a socket is never opened on an engine
    /// that is not there.
    @Test func anUpgradeBeforeTheModelIsResidentIs503() async throws {
        let running = try await Running.start(.notResident("still loading"))
        defer { running.server.stop() }
        let client = Client(running)
        await #expect(throws: (any Error).self) { try await client.task.receive() }
        let event = try await running.nextEvent()
        #expect(event.status == 503 && event.error == "model_not_ready" && event.realtime == nil)
    }
}

@Suite struct WebSocketTests {
    /// A client frame: masked, as every client frame is.
    private func masked(_ opcode: UInt8, _ payload: Data, final: Bool = true) -> Data {
        let mask: [UInt8] = [1, 2, 3, 4]
        return Data([(final ? 0x80 : 0) | opcode, 0x80 | UInt8(payload.count)] + mask) + Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
    }

    @Test func aFrameNotYetWholeIsNothingYet() throws {
        let frame = masked(0x1, Data("hello".utf8))
        #expect(try WebSocket.parse(frame.prefix(frame.count - 1), limit: 100) == nil)
        #expect(try WebSocket.parse(frame + Data([0x81]), limit: 100)?.consumed == frame.count)
    }

    @Test func fragmentsAreOneMessageAndControlFramesCutIn() throws {
        var assembler = WebSocket.Assembler()
        let frames = [masked(0x1, Data("hel".utf8), final: false), masked(0x9, Data("p".utf8)), masked(0x0, Data("lo".utf8))]
        let messages = try frames.map { try assembler.take(#require(try WebSocket.parse($0, limit: 100)).0, limit: 100) }
        #expect(messages == [nil, .ping(Data("p".utf8)), .text("hello")])
    }

    @Test(arguments: [
        (Data([0x81, 0x00]), UInt16(1002)),
        (Data([0xC1, 0x80, 0, 0, 0, 0]), UInt16(1002)),
        (Data([0x81, 0xFE, 0x10, 0x00, 0, 0, 0, 0]), UInt16(1009)),
    ])
    func aFrameBreakingTheProtocolSaysHow(bytes: Data, code: UInt16) {
        do {
            _ = try WebSocket.parse(bytes, limit: 1024)
            Issue.record("\(bytes as NSData) was read as a frame")
        } catch {
            #expect(error.code == code)
        }
    }

    /// RFC 6455's own example key and answer.
    @Test func theAcceptKeyIsTheRFCs() {
        #expect(WebSocket.accept("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }
}
