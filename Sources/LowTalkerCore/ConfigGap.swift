/// Something a config says that parses, holds together, and is still not what anyone
/// meant. None of these refuses a config: each one describes a file that will run, and
/// will do less than its author expected.
///
/// [LAW:decomposition] These are the faults that are not `ConfigError`'s to find.
/// `ConfigError` is about a file that cannot become a Config; a gap is about a Config
/// that came out fine and says nothing useful, so the two never have to agree on
/// anything and neither grows cases belonging to the other.
public enum ConfigGap: Hashable, Sendable, CustomStringConvertible {
    /// A mode whose `routes` is an empty list: it listens, and nothing it hears becomes
    /// anything. A mode with no `routes` key at all dictates, which is a different fact
    /// about a file that looks almost the same - so the one that claims nothing is
    /// named here and the one that dictates is not.
    case modeClaimsNothing(mode: String)
    /// A bundle id no app on this Mac answers to. Whether an app exists is a fact about
    /// a machine and not about a file, which is why `Config.load` cannot report it and
    /// this can.
    case noSuchApp(mode: String, app: BundleID)

    public var description: String {
        switch self {
        case .modeClaimsNothing(let mode):
            "mode \"\(mode)\" has no routes, so nothing said in it becomes anything"
        case .noSuchApp(let mode, let app):
            "mode \"\(mode)\" inserts into \(app.rawValue), which no app on this Mac answers to"
        }
    }
}

public extension Config {
    /// Every gap in this config, in the order the file declares its modes.
    ///
    /// [LAW:effects-at-boundaries] Pure. Whether an app is installed is asked of the
    /// caller, so the CLI hands this NSWorkspace and a test hands it a set of ids -
    /// which is also why the answer is the same on a machine that has Slack and one
    /// that does not, without either needing to be the machine running the test.
    func gaps(appExists: (BundleID) -> Bool) -> [ConfigGap] {
        modes.flatMap { $0.gaps(appExists: appExists) }
    }
}

private extension Mode {
    func gaps(appExists: (BundleID) -> Bool) -> [ConfigGap] {
        // One entry per id rather than per mention, so a mode routing to one missing app
        // from three routes is told about it once. Ordered, because a Set is not, and a
        // report that lists its findings in a different order each run is one nobody can
        // diff. [LAW:one-source-of-truth]
        var alreadyNamed: Set<BundleID> = []
        let missing = router.routes
            .flatMap(\.then.appsNamed)
            .filter { alreadyNamed.insert($0).inserted && !appExists($0) }
            .map { ConfigGap.noSuchApp(mode: name, app: $0) }
        let unclaimed = router.routes.isEmpty ? [ConfigGap.modeClaimsNothing(mode: name)] : []
        return unclaimed + missing
    }
}
