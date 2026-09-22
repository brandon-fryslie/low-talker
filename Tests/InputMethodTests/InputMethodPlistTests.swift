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
/// Generating costs a second and writes only build output, which is the price of reading
/// the real artifact; `make helper` already shells out to xcodegen the same way.
@Suite struct InputMethodPlistTests {
    private static func plist(for flavor: Flavor) throws -> [String: Any] {
        try #require(generated == 0, "xcodegen generate exited \(generated)")
        let url = repository.appending(path: "App/Generated/\(flavor.displayName)-InputMethod-Info.plist")
        let data = try Data(contentsOf: url)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// Run once however many cases ask for a plist: a `static let`'s initialiser is lazy and
    /// runs exactly once, which is what keeps four parallel cases from generating the
    /// project on top of each other.
    private static let generated: Int32 = {
        let xcodegen = Process()
        xcodegen.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        xcodegen.arguments = ["xcodegen", "generate", "--quiet"]
        xcodegen.currentDirectoryURL = repository
        xcodegen.standardOutput = Pipe()
        xcodegen.standardError = Pipe()
        do { try xcodegen.run() } catch { return -1 }
        xcodegen.waitUntilExit()
        return xcodegen.terminationStatus
    }()

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
}
