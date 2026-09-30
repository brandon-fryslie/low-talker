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
        #expect(realtime.refusals == ["input_audio_buffer_commit_empty": 1] && realtime.refusedAudioSeconds == nil)
    }

    /// A client that appends for longer than the limit without a commit, as Pipecat does
    /// through silence between turns, is never refused: the open item starts over from its
    /// newest audio each time it outgrows its share, so the socket never holds more than the
    /// limit, and the item committed at last is heard with no more than its share.
    /// Limit 4 s: a share of 2 s, of which 1 s is kept, so 10 s uncommitted lets go 1 s eight times.
    @Test func appendingPastTheLimitWithoutACommitStartsTheItemOverAndIsNeverRefused() async throws {
        let stub = Stub()
        let running = try await Running.start(.ready(stub), limits: ServedLimits(uploads: 1, sockets: 1, audio: 4))
        defer { running.server.stop() }
        var client = Client(running)
        try await client.append(seconds: 10)
        try await client.send(["type": "input_audio_buffer.commit"])
        let committed = try #require(try await client.until("input_audio_buffer.committed")["item_id"] as? String)
        let completed = try await client.until("conversation.item.input_audio_transcription.completed")
        #expect(completed["item_id"] as? String == committed)
        client.task.cancel(with: .normalClosure, reason: nil)
        let heard = stub.heard.withLock { $0.map(\.seconds) }
        #expect(heard.count == 9 && heard.allSatisfy { abs($0 - 2) < 0.01 })
        let realtime = try #require(try await running.nextEvent().realtime)
        #expect(realtime.appends == 100 && realtime.refusals.isEmpty && realtime.sent.errors == 0)
        #expect(realtime.items == 9 && realtime.itemsLetGo == 8 && abs(realtime.letGoAudioSeconds - 8) < 0.01)
        #expect(realtime.sent.completed == 1 && abs(realtime.audioSeconds - 2) < 0.01)
        #expect(realtime.heldAudioSeconds <= 4 && realtime.heldItems == 1)
    }

    /// A socket opened while the server holds its limit of them is refused with a 429 before
    /// it upgrades; the place is given back when a socket closes.
    @Test func aSocketPastTheLimitIsRefusedBeforeItUpgrades() async throws {
        let running = try await Running.start(.ready(Stub()), limits: ServedLimits(uploads: 1, sockets: 1, audio: 60))
        defer { running.server.stop() }
        var open = Client(running)
        _ = try await open.until("session.created")
        let refused = Client(running)
        await #expect(throws: (any Error).self) { try await refused.task.receive() }
        let refusal = try await running.nextEvent()
        #expect(refusal.status == 429 && refusal.error == "rate_limit_exceeded" && refusal.sockets == 1 && refusal.realtime == nil)
        open.task.cancel(with: .normalClosure, reason: nil)
        let closed = try await running.nextEvent()
        #expect(closed.status == 101 && closed.sockets == 1)
        var next = Client(running)
        _ = try await next.until("session.created")
        next.task.cancel(with: .normalClosure, reason: nil)
    }

    /// A socket whose items wait on a held engine goes on reading: each commit is answered,
    /// a ping is answered, and appends are taken until what the socket holds across its
    /// items, their audio and a second for each, would pass the limit. Once the engine is free every item is heard, each only
    /// after the one before it is answered, so they are answered in the order committed, and
    /// the audio they held is free again.
    @Test func aSocketWhoseItemsWaitOnTheEngineKeepsReading() async throws {
        let gated = Gated()
        let running = try await Running.start(.ready(gated), limits: ServedLimits(uploads: 1, sockets: 1, audio: 6))
        defer { running.server.stop() }
        var client = Client(running)
        var committed: [String] = []
        for _ in 0..<3 {
            try await client.append(seconds: 0.5)
            try await client.send(["type": "input_audio_buffer.commit"])
            committed.append(try #require(try await client.until("input_audio_buffer.committed")["item_id"] as? String))
        }
        // URLSession reads a pong only while a receive is pending, so the ping goes out
        // beside an update whose answer is awaited.
        let task = client.task
        async let pong: Void = withCheckedThrowingContinuation { (pong: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in error.map { pong.resume(throwing: $0) } ?? pong.resume() }
        }
        try await client.send(update([:]))
        _ = try await client.until("session.updated")
        try await pong
        try await client.append(seconds: 0.6)
        let refusal = try #require(try await client.until("error")["error"] as? [String: Any])
        #expect(refusal["code"] as? String == "audio_too_long")
        try await client.send(["type": "input_audio_buffer.commit"])
        committed.append(try #require(try await client.until("input_audio_buffer.committed")["item_id"] as? String))
        gated.gate.cancel()
        var completed: [String] = []
        for _ in 0..<4 {
            completed.append(try #require(try await client.until("conversation.item.input_audio_transcription.completed")["item_id"] as? String))
        }
        #expect(completed == committed)
        try await client.append(seconds: 1.5)
        try await client.send(["type": "input_audio_buffer.commit"])
        _ = try await client.until("conversation.item.input_audio_transcription.completed")
        client.task.cancel(with: .normalClosure, reason: nil)
        #expect(gated.started.withLock { $0 } == [0, 1, 2, 3, 4])
        let realtime = try #require(try await running.nextEvent().realtime)
        #expect(realtime.items == 5 && realtime.sent.completed == 5 && realtime.refusals == ["audio_too_long": 1])
        let refused = try #require(realtime.refusedAudioSeconds)
        #expect(abs(realtime.heldAudioSeconds - 6) < 0.01 && abs(refused - 6.1) < 0.01 && realtime.heldItems == 4)
    }

    /// An append that holds no whole sample puts no audio in the buffer, so committing it
    /// is refused as committing nothing is.
    @Test func aCommitWithNoWholeSampleIsRefusedAsEmpty() async throws {
        let running = try await Running.start(.ready(Stub()))
        defer { running.server.stop() }
        var client = Client(running)
        for audio in ["", Data([0x01]).base64EncodedString()] {
            try await client.send(["type": "input_audio_buffer.append", "audio": audio])
        }
        try await client.send(["type": "input_audio_buffer.commit"])
        let refusal = try #require(try await client.until("error")["error"] as? [String: Any])
        #expect(refusal["code"] as? String == "input_audio_buffer_commit_empty")
        #expect(!client.types().contains("input_audio_buffer.committed"))
        client.task.cancel(with: .normalClosure, reason: nil)
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

    /// A close frame's code is read off it; one a peer may not send, or a code cut to one
    /// byte, breaks the protocol.
    @Test(arguments: [
        (Data(), Result<UInt16?, WebSocket.Violation>.success(nil)),
        (Data([0x03, 0xE8]) + Data("bye".utf8), .success(1000)),
        (Data([0x03]), .failure(WebSocket.Violation(code: 1002, "a close frame's code was one byte"))),
        (Data([0x03, 0xED]), .failure(WebSocket.Violation(code: 1002, "close code 1005 is not one a peer may send"))),
        (Data([0x03, 0xE8, 0xFF]), .failure(WebSocket.Violation(code: 1007, "a close frame's reason is not UTF-8"))),
    ])
    func aCloseFramesCodeIsParsed(payload: Data, expected: Result<UInt16?, WebSocket.Violation>) throws {
        var assembler = WebSocket.Assembler()
        let frame = try #require(try WebSocket.parse(masked(0x8, payload), limit: 100)).0
        #expect(Result { () throws(WebSocket.Violation) in try assembler.take(frame, limit: 100) } == expected.map { .close($0) })
    }

    /// RFC 6455's own example key and answer.
    @Test func theAcceptKeyIsTheRFCs() {
        #expect(WebSocket.accept("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }
}
