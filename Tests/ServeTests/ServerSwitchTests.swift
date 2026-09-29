import Flavors
import Foundation
import LowTalkerCore
import Network
@testable import Serve
import Testing

/// The app's server as the person switches it (low-serve-axq.tom): off until chosen, the
/// choice kept, the port held only while on, and every request answered with the engine the
/// app hands it.
@MainActor @Suite struct ServerSwitchTests {
    /// A switch over a defaults domain of its own, listening on `port` of loopback.
    func aSwitch(on port: NWEndpoint.Port = .any, defaults: UserDefaults = scratchDefaults()) -> ServerSwitch {
        ServerSwitch(defaults: defaults) { binding, engine throws(ListenRefused) in
            try await TranscriptionServer.listen(at: ListenAddress(flavor: .development, binding: binding, port: port), engine: engine, record: { _ in })
        }
    }

    @Test func offUntilChosenAndBindsNothing() async throws {
        let server = aSwitch()
        server.resume(at: .success(.loopback))
        #expect(!server.chosen)
        #expect("\(server.state)" == "off")
        #expect(server.running == nil)
    }

    /// Answered with whatever the app last handed it: 503 while its model loads, then the
    /// model itself.
    @Test func chosenItListensAndAnswersWithTheEngineItIsHanded() async throws {
        let server = aSwitch()
        defer { server.choose(false, at: .success(.loopback)) }
        server.choose(true, at: .success(.loopback))
        let running = try await listening(server)
        let upload: [(name: String, filename: String?, value: Data)] = [
            ("model", nil, Data("m".utf8)), ("response_format", nil, Data("text".utf8)), ("file", "audio.mp3", try fixture("hello-16k-mono.mp3")),
        ]
        #expect(try await running.post(upload).0.statusCode == 503)
        server.answer(with: .ready(Stub()))
        let (response, body) = try await running.post(upload)
        #expect(response.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self) == "Hello world, this is LowTalker.\n")
        #expect("\(server.state)" == "listening at \(running.base)")
    }

    /// Switched off, the port is let go and the choice is remembered as off.
    @Test func switchedOffItLetsThePortGo() async throws {
        let defaults = scratchDefaults()
        let server = aSwitch(defaults: defaults)
        server.choose(true, at: .success(.loopback))
        let port = try await listening(server).server.port
        server.choose(false, at: .success(.loopback))
        await server.running?.value
        #expect("\(server.state)" == "off")
        #expect(!aSwitch(defaults: defaults).chosen)
        let again = try await TranscriptionServer.listen(at: ListenAddress(flavor: .development, port: port), engine: { .ready(Stub()) }, record: { _ in })
        again.stop()
    }

    /// The choice outlives the switch, as it outlives the app: another switch over the same
    /// defaults resumes listening.
    @Test func theChoiceIsKept() async throws {
        let defaults = scratchDefaults()
        aSwitch(defaults: defaults).choose(true, at: .failure(.noModes))
        let resumed = aSwitch(defaults: defaults)
        defer { resumed.choose(false, at: .success(.loopback)) }
        resumed.resume(at: .success(.loopback))
        _ = try await listening(resumed)
    }

    /// Asked again while listening, it listens again on its own port rather than being
    /// refused by the listener it is replacing.
    @Test func aRestartListensAgainOnTheSamePort() async throws {
        let port = try await freePort()
        let server = aSwitch(on: port)
        defer { server.choose(false, at: .success(.loopback)) }
        server.choose(true, at: .success(.loopback))
        _ = try await listening(server)
        server.resume(at: .success(.loopback))
        #expect(try await listening(server).server.port == port)
    }

    /// Switched off while it was still binding, the listen that answers late lets its port go
    /// rather than being left up behind a switch that reads off.
    @Test func switchedOffWhileStartingNothingIsLeftListening() async throws {
        let port = try await freePort()
        let server = aSwitch(on: port)
        server.choose(true, at: .success(.loopback))
        server.choose(false, at: .success(.loopback))
        await server.running?.value
        #expect("\(server.state)" == "off")
        let again = try await TranscriptionServer.listen(at: ListenAddress(flavor: .development, port: port), engine: { .ready(Stub()) }, record: { _ in })
        again.stop()
    }

    /// An address another process holds, and a config that names none, each leave the switch
    /// on and the server stopped, saying why.
    @Test func whatKeepsItFromListeningIsSaid() async throws {
        let holder = try await TranscriptionServer.listen(at: ListenAddress(flavor: .development, port: .any), engine: { .ready(Stub()) }, record: { _ in })
        defer { holder.stop() }
        let taken = aSwitch(on: holder.port)
        taken.choose(true, at: .success(.loopback))
        await taken.running?.value
        #expect("\(taken.state)".hasPrefix("stopped — LowTalker Dev (development) cannot serve on 127.0.0.1:\(holder.port): "))
        #expect(taken.chosen)

        let unread = aSwitch()
        unread.choose(true, at: .failure(.noModes))
        await unread.running?.value
        #expect("\(unread.state)" == "stopped — the config cannot be read: \(ConfigError.noModes)")
    }

    /// Waits until the switch reads listening, and returns its server.
    func listening(_ server: ServerSwitch) async throws -> Running {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            switch server.state {
            case .listening(let listener): return Running(server: listener, events: AsyncStream { $0.finish() })
            case .stopped(let reason): throw ListenFailed(reason: reason)
            case .off, .starting: try await Task.sleep(for: .milliseconds(10))
            }
        }
        throw ListenFailed(reason: "still \(server.state) after 30 s")
    }

    /// A port nothing holds, found by binding one and letting it go.
    func freePort() async throws -> NWEndpoint.Port {
        let probe = try await TranscriptionServer.listen(at: ListenAddress(flavor: .development, port: .any), engine: { .ready(Stub()) }, record: { _ in })
        probe.stop()
        try await probe.finished()
        return probe.port
    }
}

struct ListenFailed: Error, CustomStringConvertible {
    let reason: String
    var description: String { "the switch did not listen: \(reason)" }
}

/// A defaults domain no other test, and no installation, reads.
func scratchDefaults() -> UserDefaults {
    let name = "ServerSwitchTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}
