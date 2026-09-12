import Flavors
import Testing

@testable import lowtalker_keyboardd

/// What the helper accepts from its plist, and everything it refuses.
///
/// [LAW:behavior-not-structure] The contract is "this argv names that flavor, or none",
/// which is asserted here over argv shapes a malformed plist actually produces.
struct FlavorArgumentTests {
    @Test(arguments: Flavor.allCases)
    func theFlavorItIsGivenIsTheFlavorItReads(flavor: Flavor) {
        #expect(flavorArgument(["/path/to/helper", "--flavor", flavor.description]) == flavor)
    }

    /// The flag need not be first: launchd passes the program as argv[0] and a plist may
    /// carry other arguments before this one.
    @Test
    func theFlagIsFoundWhereverItStands() {
        #expect(flavorArgument(["helper", "--verbose", "--flavor", "development"]) == .development)
    }

    /// Every way a plist can fail to say. None of these may answer a flavor: the helper
    /// would then listen on the other installation's service and take its endpoint.
    @Test(arguments: [
        [],
        ["helper"],
        ["helper", "--flavor"],
        ["helper", "--flavor", ""],
        ["helper", "--flavor", "bogus"],
        ["helper", "--flavor", "Release"],
        ["helper", "release"],
        ["helper", "--flavour", "release"],
    ])
    func anArgvThatDoesNotSayIsRefused(arguments: [String]) {
        #expect(flavorArgument(arguments) == nil)
    }
}
