import LowTalkerCore

extension Dictation {
    /// What the loop is doing with presses now, as the status item shows it: a microphone
    /// open for a press, presses ended and still on their way to the cursor, or neither.
    ///
    /// [LAW:one-source-of-truth] Read off the loop's own press and queue, so the icon cannot
    /// say listening over a press that was refused its microphone, or ready over words still
    /// on their way.
    public enum Activity: Sendable, Equatable {
        case idle
        /// A press's microphone is open. Wins over `transcribing`: the press being spoken is
        /// the one the person is watching for.
        case listening
        /// A press has ended and its outcome is not yet reported.
        case transcribing

        /// What the status item draws: this activity while there is one, and the engine's
        /// readiness when there is none. [LAW:dataflow-not-control-flow]
        public func glyph(over readiness: EngineReadiness) -> EngineReadiness.StatusGlyph {
            switch self {
            case .idle: readiness.statusGlyph()
            case .listening: .symbol("waveform")
            case .transcribing: .symbol("text.cursor")
            }
        }

        /// What the icon says to VoiceOver, and to an agent reading the menu bar over
        /// Accessibility, for the app named `name`.
        public func iconDescription(for name: String, over readiness: EngineReadiness) -> String {
            switch self {
            case .idle: readiness.iconDescription(for: name)
            case .listening: "\(name): listening"
            case .transcribing: "\(name): transcribing"
            }
        }
    }
}
