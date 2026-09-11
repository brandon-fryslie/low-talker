import ArgumentParser
import Foundation
import LowTalkerCore

/// Captures the microphone for a while and writes what the ring holds, so the
/// capture engine can be heard, and a device switch mid-run tried, before the
/// hotkey exists. The microphone is open for the recording and no longer.
///
/// The warm-up is not visible in the wav's length - the run is timed from after the
/// engine is up, so a one-second run writes a full second whenever it wrote anything.
/// It shows in the line instead: every run of this command is the first launch in its
/// process, which on this Mac takes 244 ms against 38 ms for an engine that has run the
/// device before, so the clip says it is cut where the microphone was not open. That is
/// the reading, not a fault in the run.
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
        // The microphone opens here and closes at `endSession`, so this command holds the
        // device for exactly the seconds it records - the same lifetime a hold gets.
        let session = try capture.beginSession(at: .now)
        try await Task.sleep(for: .seconds(seconds))

        // A run longer than the ring retains, one a device switch was tried during, or one
        // whose microphone died partway is exactly what this command is for: the wav is
        // written either way and the line says what is missing from it.
        // [LAW:no-silent-failure] Refusing is `Dictation`'s answer because its destination
        // is the user's editor; here the operator is reading the line and can see the gap
        // for what it is.
        let captured = capture.endSession(session)
        let clip = switch captured {
        case .whole(let clip), .partial(let clip, _): clip
        }
        let wholeness = switch captured {
        case .whole: "whole"
        case .partial(_, let lost): "\(lost)"
        }
        try clip.write(to: output)
        // Pinned like TranscribeCommand's numbers, so the line reads the same on every machine.
        let without = capture.outages.total.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)).locale(Locale(identifier: "en_US_POSIX")))
        print("\(output.path): \(clip.duration) s, peak \(clip.peak), \(wholeness), device changes \(capture.deviceChanges), outages \(capture.outages.count) (\(without) without audio)")
    }
}
