import Foundation
@testable import LowTalkerCore
import Network
@testable import Serve
import Synchronization
import Testing

/// An engine that hears the conformance fixture's words in whatever it is given, and keeps
/// what it was given. While audio streams in it confirms a word per half second heard, up
/// to half the words, so a streamed utterance has words confirmed before it ends and
/// words left for the final transcript. Audio that never reaches the engine's audible floor
/// it refuses as nothing spoken, as the engine does.
final class Stub: Transcriber {
    let heard = Mutex<[(seconds: TimeInterval, vocabulary: Vocabulary, cancelled: Bool)]>([])
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
        var loudest: Float = 0
        for await clip in audio {
            seconds += clip.duration
            loudest = max(loudest, clip.peak)
            let confirmed = loudest < Utterance.audible ? 0 : min(words.count / 2, Int(seconds / 0.5))
            partial(Partial(confirmed: Transcript(words: Array(words.prefix(confirmed))), tentative: Transcript(words: []), repunctuated: 0))
        }
        heard.withLock { $0.append((seconds, vocabulary, Task.isCancelled)) }
        guard loudest >= Utterance.audible else { throw UtteranceError.nothingSpoken(peak: loudest) }
        return try answer.get()
    }
}

/// The stub, heard as a served caller of `turns`, as the app's engine is.
struct Turning: Transcriber {
    let turns: EngineTurns

    func transcribe(
        _ audio: some AsyncSequence<AudioClip, Never> & Sendable,
        expecting vocabulary: Vocabulary,
        partial: @escaping @Sendable (Partial) -> Void
    ) async throws -> Transcript {
        var clip: [Float] = []
        for await chunk in audio { clip += chunk.samples }
        return try await turns.decode(as: .served) { [clip] in
            try await Stub().transcribe(AudioClip(samples: clip), expecting: vocabulary)
        }
    }
}

/// The stub, answering nothing until `gate` is cancelled, and recording for each transcribe
/// how many had been answered when it started.
final class Gated: Transcriber {
    let gate = Task<Void, Never> { try? await Task.sleep(for: .seconds(3600)) }
    let started = Mutex<[Int]>([])
    private let answered = Mutex(0)

    func transcribe(
        _ audio: some AsyncSequence<AudioClip, Never> & Sendable,
        expecting vocabulary: Vocabulary,
        partial: @escaping @Sendable (Partial) -> Void
    ) async throws -> Transcript {
        started.withLock { $0.append(answered.withLock { $0 }) }
        await gate.value
        defer { answered.withLock { $0 += 1 } }
        return try await Stub().transcribe(audio, expecting: vocabulary, partial: partial)
    }
}

struct StubFailure: Error, CustomStringConvertible {
    var description: String { "the stub engine was told to fail" }
}

/// A server on a port the system chose, on loopback unless bound elsewhere, and every event
/// it records.
struct Running {
    let server: TranscriptionServer
    let events: AsyncStream<ServedRequest>

    static func start(_ engine: ServedEngine, on binding: ServeBinding = .loopback, limits: ServedLimits = .standard) async throws -> Running {
        let (events, sink) = AsyncStream<ServedRequest>.makeStream()
        let server = try await TranscriptionServer.listen(at: ListenAddress(binding: binding, port: .any), limits: limits, engine: { engine }, record: { sink.yield($0) })
        return Running(server: server, events: events)
    }

    /// Bound to this Mac's LAN address, the case a token exists for, requiring `token`.
    static func startOnTheLAN(_ engine: ServedEngine, token: String) async throws -> Running {
        try await start(engine, on: .interface(InterfaceAddress(try lanAddress()), token: BearerToken(token)))
    }

    /// Every result `scripts/conformance check` reports against this server, sending `token`
    /// when one is given, as the suite reads it: from the environment, never the command line.
    func conformance(token: String? = nil) async throws -> [[String: Any]] {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let suite = Process()
        suite.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        suite.arguments = ["python3", repository.appendingPathComponent("scripts/conformance").path, "check", base]
            + (token == nil ? [] : ["--token-env", "LOWTALKER_CONFORMANCE_TOKEN"])
        suite.environment = ProcessInfo.processInfo.environment.merging(token.map { ["LOWTALKER_CONFORMANCE_TOKEN": $0] } ?? [:]) { $1 }
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
        return try #require((JSONSerialization.jsonObject(with: summary) as? [String: Any])?["results"] as? [[String: Any]], "\(printed)")
    }

    var base: String { server.baseURL }

    func post(_ fields: [(name: String, filename: String?, value: Data)], path: String = "audio/transcriptions", authorization: String? = nil) async throws -> (HTTPURLResponse, Data) {
        let boundary = UUID().uuidString
        var body = Data()
        for field in fields {
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field.name)\"".utf8)
            body += Data((field.filename.map { "; filename=\"\($0)\"" } ?? "").utf8) + Data("\r\n\r\n".utf8)
            body += field.value + Data("\r\n".utf8)
        }
        body += Data("--\(boundary)--\r\n".utf8)
        return try await post(body, boundary: boundary, path: path, authorization: authorization)
    }

    func post(_ body: Data, boundary: String = "b", path: String = "audio/transcriptions", authorization: String? = nil) async throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: URL(string: "\(base)/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        request.setValue(authorization, forHTTPHeaderField: "authorization")
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        return (response as! HTTPURLResponse, data)
    }

    func nextEvent() async throws -> ServedRequest {
        var iterator = events.makeAsyncIterator()
        return try #require(await iterator.next())
    }
}

/// The IPv4 address of the first interface that is up and is not loopback.
func lanAddress() throws -> String {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { throw POSIXError(.init(rawValue: errno)!) }
    defer { freeifaddrs(list) }
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(entry.pointee.ifa_flags)
        guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
              flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    throw NoLANAddress()
}

struct NoLANAddress: Error, CustomStringConvertible {
    var description: String { "no interface on this Mac is up with an IPv4 address off loopback" }
}

func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")))
}

/// `seconds` of 16 kHz audio peaking at `peak`, as the wav file an upload carries.
func wav(seconds: TimeInterval, peak: Float) throws -> Data {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lowtalker-test-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let count = AudioClip.sampleCount(for: seconds)
    try AudioClip(samples: (0..<count).map { peak * Float(sin(Double($0) * 2 * .pi * 440 / 16_000)) }).write(to: url)
    return try Data(contentsOf: url)
}

func error(_ body: Data) throws -> [String: Any] {
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    return try #require(object["error"] as? [String: Any])
}
