import Flavors
import Testing

/// The input method process learns which installation it is from the identifier macOS
/// launched it under, and from nothing else.
@Suite struct InputMethodFlavorTests {
    @Test(arguments: Flavor.allCases)
    func aFlavorsInputMethodIdentifierParsesBackToIt(flavor: Flavor) {
        #expect(Flavor(inputMethodBundleIdentifier: flavor.inputMethodBundleIdentifier) == flavor)
    }

    /// The app's own identifier is not the input method's, so it must not answer here
    /// either: a process that took it would be reading the flavor off a bundle it is not.
    @Test(arguments: Flavor.allCases)
    func theAppsOwnIdentifierIsNotAnInputMethods(flavor: Flavor) {
        #expect(Flavor(inputMethodBundleIdentifier: flavor.bundleIdentifier) == nil)
    }

    /// [LAW:no-silent-failure] Nil rather than a guess, for the same reason the app's parser
    /// refuses: the next thing the process does with a flavor is open that flavor's port.
    @Test(arguments: [
        "ai.promptctl.low-talker.inputmethod",
        "ai.promptctl.low-talker.inputmethod.dictation.text",
        "com.apple.inputmethod.Ainu",
        "",
    ])
    func anIdentifierThatIsNoInputMethodsIsRefused(identifier: String) {
        #expect(Flavor(inputMethodBundleIdentifier: identifier) == nil)
    }
}
