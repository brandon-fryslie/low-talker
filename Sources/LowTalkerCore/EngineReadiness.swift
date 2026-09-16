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
    /// Not yet able to hear, waiting `since` that instant: `phase` is nil until the load
    /// reports its first step.
    case preparing(WhisperKitTranscriber.LoadPhase?, since: ContinuousClock.Instant)
    /// Loaded, the wait having lasted `after`. Kept rather than measured when read, so the
    /// menu opened an hour later says how long the load took, not how long ago launch was.
    case ready(ModelName, after: Duration)
    /// The load stopped with this reason, and nothing will retry it until the next launch.
    case failed(String)

    /// This state once the load has reported `phase`. Only a wait advances: a report
    /// that arrives after the load has already finished or failed leaves that verdict
    /// standing.
    ///
    /// [LAW:no-ambient-temporal-coupling] Load phases reach the main actor as tasks of
    /// their own, and nothing orders them against the load's return, so a "copying"
    /// queued just before a fast failure can run after it. The transition, not the
    /// timing, is what keeps a failed load from being drawn as a wait forever.
    public func reporting(_ phase: WhisperKitTranscriber.LoadPhase) -> EngineReadiness {
        switch self {
        case .preparing(_, let since): .preparing(phase, since: since)
        case .ready, .failed: self
        }
    }

    /// The words for the menu and the log, read at `now`. A wait says how long it has run,
    /// which is what tells a slow load from a stuck one.
    public func readout(at now: ContinuousClock.Instant) -> String {
        switch self {
        case .preparing(let phase, let since): "\(phase?.description ?? "checking the model"), \(Self.spoken(since.duration(to: now))) so far"
        case .ready(let model, let wait): "ready (\(model)) after \(Self.spoken(wait))"
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
        case .ready: wordsOnClipboard ? "\(name): last dictation copied to the clipboard" : name
        case .failed: "\(name): the model failed to load"
        }
    }

    /// Whole seconds, as a person reads a wait: "48 s", "2 min 44 s".
    static func spoken(_ elapsed: Duration) -> String {
        let seconds = Int(elapsed.components.seconds)
        return seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
    }
}
