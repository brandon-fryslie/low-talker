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
    @OptionGroup var source: SourceOptions

    @OptionGroup var installation: FlavorOption

    @MainActor
    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let reporter = PhaseReporter()
        let transcriber = try await WhisperKitTranscriber.load(options.model, in: options.store(), from: source.source, phase: reporter.report)
        let capture = AudioCapture()
        // The resting mode is not read from the config here, and not because the config is
        // unavailable: a command run from a terminal is watched by the operator who ran it
        // and ends when they interrupt it, so the reason to hold the microphone between
        // presses - an agent running all day that the user has to be able to trust - is
        // not this command's situation. The app is where that setting is honoured.
        try capture.start(try await MicrophonePermission().request().grant(), atRest: .shut)
        // Readied before the tap goes up, so the first press opens a microphone already reached.
        capture.waitUntilReadied()
        // Watched before the tap goes up, so no key can be down when an interrupt lands.
        let interrupt = Interrupt.watched()
        let helper = HelperConnection(flavor: installation.flavor)
        let chord = Hotkey.defaultChord(for: installation.flavor, heardBy: .virtualKeyboard)
        // [LAW:decomposition] What this installation listens for and what its typist must
        // refuse to press are two sets that happened to be equal while there was one
        // installation. Listening is this copy's own chord - hearing the other's would be
        // dictating on somebody else's hotkey - while refusing has to cover every chord
        // any copy listens for, because the keystrokes reach macOS as hardware.
        let listening: Set<KeyChord> = [chord]
        let dictation = Dictation(
            capture: capture,
            transcriber: { transcriber },
            router: .dictation,
            executor: Executor.guarding(keyboard: helper.keyboard, mouse: helper.mouse, interrupt: interrupt),
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
        let hotkey = Hotkey(chords: listening)
        // A tap that has come down will never hear another press, and a command that goes
        // on polling looks ready while being deaf - with the one line that said otherwise
        // long scrolled away. [LAW:no-silent-failure] The loop below ends on it, so the
        // reason is the last thing printed and a script reads it off the exit code.
        let cameDown = CameDown()
        try hotkey.start(dictation.press) { lapse in
            print("\(lapse)")
            if case .comeDown = lapse.response { cameDown.lapse = lapse }
        }
        print("ready: hold \(Hotkey.held(chord)) to dictate")
        // The tap runs on the main run loop; this keeps the command on it until the
        // operator's interrupt, which is read rather than let end the process, so a
        // session it lands in still releases its keys.
        do {
            while true {
                try interrupt.check()
                if let lapse = cameDown.lapse { throw HotkeyCameDown(lapse: lapse) }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            // The release happens on the session's own way out, so the process may not
            // go before the session has: returning here at the speed of the poll would
            // beat a burst to its release and leave a key down. The tap comes down and
            // hands over what it had already read before the wait, which is what lets
            // that wait cover the last press.
            await hotkey.stopAndDeliver()
            try await dictation.finish()
            throw error
        }
    }
}

/// Where the hotkey's come-down report is left for the polling loop to find. A class
/// because the report arrives at a closure the command handed over before the loop began.
@MainActor private final class CameDown {
    var lapse: KeyboardTapLapse?
}

/// The tap came down, so this command can hear nothing more.
///
/// An error rather than a line on the way past: it is the reason the command ended, and
/// a non-zero exit is how anything but a person reading the scrollback finds that out.
private struct HotkeyCameDown: Error, CustomStringConvertible {
    let lapse: KeyboardTapLapse

    var description: String { "\(lapse)" }
}
