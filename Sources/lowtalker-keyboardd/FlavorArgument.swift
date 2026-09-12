import Flavors

/// The `--flavor <word>` that this helper's launchd plist passes it.
///
/// [LAW:parse-dont-validate] The one place the helper's argv becomes a flavor. What comes
/// back is the flavor or nothing; there is no third answer and no default, because the two
/// installations run side by side and a helper that guessed which one it served would
/// listen on the other copy's Mach service - taking the endpoint from the helper that
/// belongs there, silently, which is the whole failure this design exists to remove.
/// [LAW:no-silent-failure]
///
/// [LAW:effects-at-boundaries] Pure, taking the arguments rather than reading
/// `CommandLine` itself, so every shape of a malformed plist is a test and not a daemon
/// that has to be installed to find out.
func flavorArgument(_ arguments: [String]) -> Flavor? {
    guard let flag = arguments.firstIndex(of: "--flavor") else { return nil }
    let word = arguments.index(after: flag)
    guard word < arguments.endIndex else { return nil }
    return Flavor(word: arguments[word])
}
