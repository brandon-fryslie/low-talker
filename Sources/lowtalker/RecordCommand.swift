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

    @Option(help: "How long to capture. The ring retains 60 s, so a longer run writes the last 60.")
    var seconds: Double = 5

    @Argument(help: "Where to write the wav.", transform: URL.init(fileURLWithPath:))
    var output: URL

    @MainActor
    mutating func run() async throws {
        let capture = AudioCapture()
        try capture.start()
        try await Task.sleep(for: .seconds(seconds))
        let state = capture.state
        capture.stop()
        if case .failed(let error) = state { throw error }

        let clip = capture.clip(in: capture.retained)
        try clip.write(to: output)
        print("\(output.path): \(clip.duration) s, peak \(clip.peak), device changes \(capture.deviceChanges)")
    }
}
