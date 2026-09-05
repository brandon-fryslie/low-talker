import ArgumentParser
import Foundation
import LowTalkerCore

/// Captures the microphone for a while and writes what the ring holds, so the
/// capture engine can be heard, and a device switch mid-run tried, before the
/// hotkey exists.
struct RecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Capture the microphone into a 16 kHz mono wav."
    )

    @Option(help: "How long to capture. The ring retains \(AudioCapture.defaultRetention.formatted()) s, so a longer run writes only that much.")
    var seconds: Double = 5

    @Argument(help: "Where to write the wav.", transform: URL.init(fileURLWithPath:))
    var output: URL

    func validate() throws {
        guard seconds > 0 else { throw ValidationError("--seconds must be positive.") }
    }

    @MainActor
    mutating func run() async throws {
        // Prompts on a Mac that has never been asked; the grant is what `start` requires.
        let grant = try await MicrophonePermission().request().grant()
        let capture = AudioCapture()
        try capture.start(grant)
        defer { capture.stop() }
        let session = capture.beginSession()
        try await Task.sleep(for: .seconds(seconds))
        if case .failed(let error) = capture.state { throw error }

        let clip = capture.endSession(session)
        try clip.write(to: output)
        print("\(output.path): \(clip.duration) s, peak \(clip.peak), device changes \(capture.deviceChanges)")
    }
}
