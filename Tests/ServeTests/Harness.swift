import Foundation
import LowTalkerCore
import Flavors
import Network
@testable import Serve
import Synchronization
import Testing

/// An engine that hears the conformance fixture's words in whatever it is given, and keeps
/// what it was given. While audio streams in it confirms a word per half second heard, up
/// to half the words, so a streamed utterance has words confirmed before it ends and
/// words left for the final transcript.
final class Stub: Transcriber {
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
        let words = (try? answer.get())?.words ?? []
        var seconds: TimeInterval = 0
        for await clip in audio {
            seconds += clip.duration
            let confirmed = min(words.count / 2, Int(seconds / 0.5))
            partial(Partial(confirmed: Transcript(words: Array(words.prefix(confirmed))), tentative: Transcript(words: [])))
        }
        heard.withLock { $0.append((seconds, vocabulary)) }
        return try answer.get()
    }
}

struct StubFailure: Error, CustomStringConvertible {
    var description: String { "the stub engine was told to fail" }
}

/// A server on a loopback port the system chose, and every event it records.
struct Running {
    let server: TranscriptionServer
    let events: AsyncStream<ServedRequest>

    static func start(_ engine: ServedEngine) async throws -> Running {
        let (events, sink) = AsyncStream<ServedRequest>.makeStream()
        let server = try await TranscriptionServer.listen(at: ListenAddress(flavor: .development, port: .any), engine: { engine }, record: { sink.yield($0) })
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

func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")))
}

func error(_ body: Data) throws -> [String: Any] {
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    return try #require(object["error"] as? [String: Any])
}
