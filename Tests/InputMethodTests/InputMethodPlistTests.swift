import AppKit
import Flavors
import Foundation
import InputMethod
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The bundle each flavor's input method is built as carries every name macOS files it
/// under, and carries that flavor's.
///
/// Read off the plist xcodegen actually writes rather than off project.yml's template,
/// because the template is written in placeholders and what ships is the substitution.
/// [LAW:behavior-not-structure] A test that asserted the template mentions
/// `${inputSourceIdentifier}` would pass on a project.yml that put it under the wrong key.
///
/// Writing that plist is the build's job and not this suite's. [LAW:effects-at-boundaries]
/// A case that generated it would be a unit test deleting `App/Generated` and rewriting
/// `LowTalker.xcodeproj` in the working tree - underneath whatever build is already running
/// there, and leaving the directory deleted on a machine with no xcodegen on PATH. `make
/// test` runs xcodegen first, the way `make app` does, and the cases here only read.
///
/// So a stale plist for a target since deleted from project.yml is not this suite's to
/// catch, and it does not try: `ProjectFlavorTests.everyKindOfTargetIsBuiltOncePerFlavor`
/// is the one checkpoint for "every flavor builds every kind of target", and a second one
/// here would be a second rulebook to keep in step. [LAW:single-enforcer]
@Suite struct InputMethodPlistTests {
    private static func plist(for flavor: Flavor) throws -> [String: Any] {
        let url = repository.appending(path: "App/Generated/\(flavor.displayName)-InputMethod-Info.plist")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "\(url.lastPathComponent) has not been generated; run `make test`, which runs xcodegen - `swift test` alone does not")
        let data = try Data(contentsOf: url)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// The three names `Flavor` decides, in the three keys macOS reads them from.
    @Test(arguments: Flavor.allCases)
    func theBundleIsNamedByItsFlavor(flavor: Flavor) throws {
        let plist = try Self.plist(for: flavor)
        // Xcode substitutes the identifier from PRODUCT_BUNDLE_IDENTIFIER, which
        // `ProjectFlavorTests` holds to `Flavor`; what this file decides is the rest.
        #expect(plist["CFBundleIdentifier"] as? String == "$(PRODUCT_BUNDLE_IDENTIFIER)")
        #expect(plist["InputMethodConnectionName"] as? String == flavor.inputMethodConnectionName)

        let modes = try #require(plist["ComponentInputModeDict"] as? [String: Any])
        let list = try #require(modes["tsInputModeListKey"] as? [String: Any])
        let mode = try #require(list[flavor.inputSourceIdentifier] as? [String: Any],
                                "no mode under \(flavor.inputSourceIdentifier); the plist declares \(Array(list.keys))")
        #expect(mode["TISInputSourceID"] as? String == flavor.inputSourceIdentifier)
        // A mode nobody can see is a source that never appears in the Input menu, and
        // nothing says so. [LAW:no-silent-failure]
        #expect(mode["tsInputModeIsVisibleKey"] as? Bool == true)
        #expect(modes["tsVisibleInputModeOrderedArrayKey"] as? [String] == [flavor.inputSourceIdentifier])
    }

    /// What macOS needs to launch the bundle as an input method at all: the class it asks
    /// the Objective-C runtime for, and a process that shows no UI of its own.
    @Test(arguments: Flavor.allCases)
    func theBundleIsLaunchableAsAnInputMethod(flavor: Flavor) throws {
        let plist = try Self.plist(for: flavor)
        // One fact in two places - the string macOS resolves at launch, and the name the
        // class actually answers to. A rename on either side alone is a bundle that
        // launches and then cannot serve. [LAW:one-source-of-truth]
        #expect(plist["InputMethodServerControllerClass"] as? String == NSStringFromClass(DictationInputController.self))
        #expect(plist["LSUIElement"] as? Bool == true)
        #expect(plist["TISIntendedLanguage"] as? String == "en")
    }

    /// The Input menu draws a glyph beside the name, and the plist names the file it draws.
    /// Held to a file that is actually in the tree, because a renamed asset leaves the key
    /// pointing at nothing and the menu simply draws no icon - nothing fails, nothing says
    /// so. [LAW:no-silent-failure]
    @Test(arguments: Flavor.allCases)
    func theBundleCarriesTheIconTheMenuDraws(flavor: Flavor) throws {
        let plist = try Self.plist(for: flavor)
        let named = try #require(plist["tsInputMethodIconFileKey"] as? String)
        #expect(plist["TISIconIsTemplate"] as? Bool == true)
        let modes = try #require(plist["ComponentInputModeDict"] as? [String: Any])
        let list = try #require(modes["tsInputModeListKey"] as? [String: Any])
        let mode = try #require(list[flavor.inputSourceIdentifier] as? [String: Any])
        #expect(mode["tsInputModeMenuIconFileKey"] as? String == named)
        #expect(FileManager.default.fileExists(atPath: repository.appending(path: "App/InputMethods/\(named)").path),
                "the plist names \(named), which App/InputMethods does not hold")
    }
}
