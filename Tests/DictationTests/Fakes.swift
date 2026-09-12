import AVFoundation
import Keystrokes
import LowTalkerCore
import Pointing
import Synchronization
import Typing

/// Hardware a test feeds: one engine per launch, its samples the test's to append.
@MainActor
final class FakeHardware: AudioHardware {
    final class Engine {
        let appending: @Sendable ([Float], HostTime) -> Void
        let onFailure: @MainActor (any Error) -> Void
        let onConfigurationChange: @MainActor () -> Void

        init(appending: @escaping @Sendable ([Float], HostTime) -> Void, onFailure: @escaping @MainActor (any Error) -> Void, onConfigurationChange: @escaping @MainActor () -> Void) {
            self.appending = appending
            self.onFailure = onFailure
            self.onConfigurationChange = onConfigurationChange
        }
    }

    private(set) var engines: [Engine] = []
    /// What a launch does, once set: throw, as a device that cannot feed the pipeline
    /// does. The microphone opens per press now, so this is the shape of a Mac with
    /// nothing to record with at the moment a key goes down.
    var failingToLaunch: (any Error)?

    /// The engine that is open, which a launch sets and its disposal gives back, so it is
    /// empty exactly when the microphone is shut.
    private var open: Engine?

    /// The engine capture is listening to now, and a replaced one never delivers again.
    /// Under `shut` there is one only while a press is open, so speaking between presses
    /// is a test describing a Mac that does not exist; under `open` the microphone is held
    /// across them, and speaking before a press is the look-back that mode is held for.
    var live: Engine {
        guard let engine = open else { preconditionFailure("nothing is capturing; the microphone opens for a press unless the resting mode holds it") }
        return engine
    }

    func launch(appending: @escaping @Sendable ([Float], HostTime) -> Void, onFailure: @escaping @MainActor (any Error) -> Void, onConfigurationChange: @escaping @MainActor () -> Void) throws -> Disposal {
        if let failingToLaunch { throw failingToLaunch }
        let engine = Engine(appending: appending, onFailure: onFailure, onConfigurationChange: onConfigurationChange)
        engines.append(engine)
        open = engine
        // Only while it is still the one open: a disposal arriving after its replacement
        // launched would shut a microphone that is listening.
        return { [weak self] in if self?.open === engine { self?.open = nil } }
    }

    func watchDefaultInput(_ onChange: @escaping @MainActor () -> Void) throws -> Disposal { {} }
}

struct Authorized: MicrophoneAuthority {
    func status() -> AVAuthorizationStatus { .authorized }
    func requestAccess() async -> Bool { true }
}

/// An engine that answers however the test says, and keeps what it was given to
/// hear. One fake for every behavior - a scripted transcript, a refusal, a wait on a
/// gate - since the answer is a value. [LAW:composability]
final class FakeTranscriber: Transcriber {
    private let heard = Mutex<[AudioClip]>([])
    private let answer: @Sendable (AudioClip) async throws -> Transcript

    init(_ answer: @escaping @Sendable (AudioClip) async throws -> Transcript) {
        self.answer = answer
    }

    /// Every utterance so far, each as the one clip its audio added up to.
    var clips: [AudioClip] { heard.withLock { $0 } }

    func transcribe(_ audio: some AsyncSequence<AudioClip, Never> & Sendable, expecting vocabulary: Vocabulary, partial: @escaping @Sendable (Partial) -> Void) async throws -> Transcript {
        var samples: [Float] = []
        for await clip in audio { samples += clip.samples }
        let clip = AudioClip(samples: samples)
        heard.withLock { $0.append(clip) }
        return try await answer(clip)
    }
}

/// A keyboard that records every call, and refuses all of them once told to.
@MainActor
final class LoggingKeyboard: Keyboard {
    private(set) var log: [String] = []
    var refusing = false
    /// What a key-down waits for once it is recorded, as a real one waits for the device to
    /// answer. Nothing, unless a test wants a session held mid-keystroke.
    var acknowledgement: @MainActor () async -> Void = {}

    private func record(_ what: String) throws {
        guard !refusing else { throw Refused() }
        log.append(what)
    }

    func check() throws { try record("check") }

    func down(_ usage: Usage) async throws {
        try record("down \(String(usage.rawValue, radix: 16))")
        await acknowledgement()
    }

    func releaseAll() throws { try record("up") }
}

struct Refused: Error {}

/// The pointer a dictation session must never reach for. The default route inserts text
/// and nothing else, so a report arriving here means the loop grew a mouse behind the
/// test's back.
///
/// [LAW:no-silent-failure] It throws rather than records: a recorded report that no test
/// asserts on is a pointer the loop could use unnoticed, which is the whole thing this
/// fake exists to catch.
@MainActor
final class UnusedMouse: Mouse {
    struct Pointed: Error, CustomStringConvertible {
        let report: String
        var description: String { "a dictation session posted \(report) to the mouse" }
    }

    func check() throws {}
    func down(_ button: Button) throws { throw Pointed(report: "down \(button.rawValue)") }
    func releaseAll() throws { throw Pointed(report: "release") }
    func move(by delta: Move) throws { throw Pointed(report: "move") }
    func scroll(by delta: Scroll) throws { throw Pointed(report: "scroll") }
}
