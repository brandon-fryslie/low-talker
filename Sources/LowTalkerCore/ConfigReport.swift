/// A config read back to the person who wrote it: where it came from, what it would
/// run, and every gap in it.
///
/// This is what `lowtalker config check` prints. It is computed rather than printed so
/// a test can read the report as a value instead of scraping a terminal, and so the
/// menu-bar app can show the same words without spelling them a second time.
/// [LAW:effects-at-boundaries]
public struct ConfigReport: CustomStringConvertible {
    public let loaded: Config.Loaded
    public let gaps: [ConfigGap]

    /// - Parameter appExists: whether this Mac has an app with that bundle id. Asked
    ///   here, at the one boundary that touches the machine, so everything below is a
    ///   pure function of the answer.
    public init(_ loaded: Config.Loaded, appExists: (BundleID) -> Bool) {
        self.loaded = loaded
        self.gaps = loaded.config.gaps(appExists: appExists)
    }

    /// Every section is present every time, and an empty one shows as a heading with
    /// nothing under it: a mode with no vocabulary says so, rather than leaving its
    /// reader to wonder whether the key was read and ignored. Which is also why there
    /// is no branch here - the lists vary, the shape does not.
    /// [LAW:dataflow-not-control-flow]
    public var description: String {
        let config = loaded.config
        let modes = config.modes.flatMap { mode in
            ["", "mode \"\(mode.name)\"", "  chord: \(mode.chord)", "  vocabulary:"]
                + mode.vocabulary.terms.map { "    \($0)" }
                + ["  routes:"]
                + mode.router.routes.map { "    \($0)" }
        }
        return (["\(loaded)", "", "model: \(config.model)", "microphone: \(config.microphone)"]
            + modes
            + ["", "gaps:"]
            + gaps.map { "  \($0)" }).joined(separator: "\n")
    }
}
