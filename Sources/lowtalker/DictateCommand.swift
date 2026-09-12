import ArgumentParser
import Flavors
import Dictation
import Foundation
import KeyboardService
import LowTalkerCore
import Typing

/// The whole loop from the terminal: hold Right Option, speak, release, and what was
/// said is typed into the app in front.
///
/// The CLI is not the app: macOS charges a terminal command's event tap to the
/// terminal, so this runs under the terminal's Accessibility and Input Monitoring and
/// the loop can be proven on a Mac before the app has its own. The app wires the same
/// `Dictation`; the one difference here is that the engine is loaded before the tap
/// goes up, so "ready" on stdout means a press will type.
struct DictateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dictate",
        abstract: "Hold Right Option, speak, release: type what was said into the app in front, until interrupted."
    )

    @OptionGroup var options: ModelOptions

    @OptionGroup var installation: FlavorOption

    @MainActor
    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let reporter = PhaseReporter()
        let transcriber = try await WhisperKitTranscriber.load(options.model, from: options.store(), phase: reporter.report)
        let capture = AudioCapture()
        // The resting mode is not read from the config here, and not because the config is
        // unavailable: a command run from a terminal is watched by the operator who ran it
        // and ends when they interrupt it, so the reason to hold the microphone between
        // presses - an agent running all day that the user has to be able to trust - is
        // not this command's situation. The app is where that setting is honoured.
        try capture.start(try await MicrophonePermission().request().grant(), atRest: .shut)
        // Watched before the tap goes up, so no key can be down when an interrupt lands.
        let interrupt = Interrupt.watched()
        let helper = HelperConnection(flavor: installation.flavor)
        let chords: Set<KeyChord> = [Hotkey.defaultChord]
        let dictation = Dictation(
            capture: capture,
            transcriber: { transcriber },
            router: Router(routes: [.dictation]),
            executor: Executor.guarding(keyboard: helper.keyboard, mouse: helper.mouse, interrupt: interrupt, hotkeys: chords),
            report: { outcome in
                switch outcome {
                case .success(let session):
                    print("\(session): \(session.transcript.text)")
                    session.performed.forEach { print("  \($0)") }
                case .failure(let error):
                    print("session failed: \(error)")
                }
            }
        )
        let hotkey = Hotkey(chords: chords)
        try hotkey.start(dictation.press) { print("\($0)") }
        print("ready: hold \(Hotkey.defaultChord.spelled) to dictate")
        // The tap runs on the main run loop; this keeps the command on it until the
        // operator's interrupt, which is read rather than let end the process, so a
        // session it lands in still releases its keys.
        do {
            while true {
                try interrupt.check()
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            // The release happens on the session's own way out, so the process may not
            // go before the session has: returning here at the speed of the poll would
            // beat a burst to its release and leave a key down.
            try await dictation.finish()
            throw error
        }
    }
}
