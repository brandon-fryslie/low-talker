import ArgumentParser
import Foundation
import LowTalkerCore

/// Captures the microphone for a while and writes what the ring holds, so the
/// capture engine can be heard, and a device switch mid-run tried, before the
/// hotkey exists. The microphone is open for the recording and no longer.
///
/// The warm-up is not visible in the wav's length - the run is timed from after the
/// microphone is open, so a one-second run writes a full second whenever it wrote
/// anything. It is no longer visible in the line either. It used to be: every run of this
/// command is the first press in its process, and while a press built its own engine that
/// cost far more than `AudioCapture.warmUpAllowance` allows, so the clip always came back
/// cut where the microphone was not open and that was the reading rather than a fault.
/// Now `start` readies the microphone and the press opens one already reached, which is
/// inside the allowance - so a run comes back whole, and one that says it is cut is a
/// fault to chase.
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
        // Shut at rest whatever the config says: this command exists to hold the device for
        // a named number of seconds and give it back, and a resting mode that held it open
        // would make the recording it takes a different length from the one it reports.
        try capture.start(grant, atRest: .shut)
        defer { capture.stop() }
        // The microphone opens here and closes at `endSession`, so this command holds the
        // device for exactly the seconds it records - the same lifetime a hold gets.
        let session = try capture.beginSession(at: .now)
        try await Task.sleep(for: .seconds(seconds))

        // What the microphone was doing, read while it is still readable: a device that died
        // mid-run leaves capture failed, and `endSession` gives the microphone back to a
        // shut resting state, which reads the same as a healthy one. Read afterwards, an
        // engine that stopped and said why would print as a clip that is merely cut, and
        // the operator would be left to guess which of the two had happened.
        // [LAW:no-silent-failure]
        let doing = capture.doing

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
        print("\(output.path): \(clip.duration) s, peak \(clip.peak), \(wholeness), microphone \(doing), device changes \(capture.deviceChanges), outages \(capture.outages.count) (\(without) without audio)")
    }
}
