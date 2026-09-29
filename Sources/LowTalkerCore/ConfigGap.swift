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

    public var description: String {
        switch self {
        case .modeClaimsNothing(let mode):
            "mode \"\(mode)\" has no routes, so nothing said in it becomes anything"
        }
    }
}

public extension Config {
    /// Every gap in this config, in the order the file declares its modes.
    var gaps: [ConfigGap] {
        modes.filter(\.router.routes.isEmpty).map { .modeClaimsNothing(mode: $0.name) }
    }
}
