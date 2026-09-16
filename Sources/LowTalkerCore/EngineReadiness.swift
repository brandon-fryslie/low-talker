import Foundation

/// Where the app's engine stands between launch and the first moment it can hear, as the
/// menu bar shows it.
///
/// The wait is long enough to need a face of its own. A first load on a Mac specializes the
/// model for the Neural Engine, 164 to 199 s for the default model on an M2 Max, and a menu bar
/// icon drawn the same through that wait as after it reads as an app that is ready and not
/// answering.
///
/// [LAW:one-source-of-truth] The icon and the words are both read off this one value, so
/// the menu bar cannot show a microphone while the menu says the model failed.
public enum EngineReadiness: Sendable, Equatable {
    /// Launched, and not yet able to hear: `phase` is nil until the load reports its first
    /// step.
    case preparing(WhisperKitTranscriber.LoadPhase?)
    case ready(ModelName)
    /// The load stopped with this reason, and nothing will retry it until the next launch.
    case failed(String)

    /// The words for the menu and the log, `elapsed` after launch. A wait says how long it
    /// has run, which is what tells a slow load from a stuck one.
    public func readout(after elapsed: Duration) -> String {
        switch self {
        case .preparing(let phase): "\(phase?.description ?? "checking the model"), \(Self.spoken(elapsed)) so far"
        case .ready(let model): "ready (\(model)) after \(Self.spoken(elapsed))"
        case .failed(let reason): "failed — \(reason)"
        }
    }

    /// The SF Symbol the status item draws. `wordsOnClipboard` only shows once the engine
    /// is ready: a press waits for the engine, so no words can be waiting before it is.
    public func symbolName(wordsOnClipboard: Bool) -> String {
        switch self {
        case .preparing: "hourglass"
        case .ready: wordsOnClipboard ? "doc.on.clipboard.fill" : "mic.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    /// What the icon says to VoiceOver, and to an agent reading the menu bar over
    /// Accessibility, for the installation named `name`.
    public func iconDescription(for name: String, wordsOnClipboard: Bool) -> String {
        switch self {
        case .preparing: "\(name): preparing the model"
        case .ready: wordsOnClipboard ? "\(name): dictation on the clipboard" : name
        case .failed: "\(name): the model failed to load"
        }
    }

    /// Whole seconds, as a person reads a wait: "48 s", "2 min 44 s".
    static func spoken(_ elapsed: Duration) -> String {
        let seconds = Int(elapsed.components.seconds)
        return seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
    }
}
