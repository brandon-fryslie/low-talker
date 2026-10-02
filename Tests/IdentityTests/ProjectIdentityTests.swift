import Identity
import Foundation
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// project.yml builds one app, under `AppIdentity`'s names.
///
/// xcodegen cannot read a Swift constant, so the names `AppIdentity` decides are written
/// again in project.yml, and this is what keeps the app's copies from drifting; the input
/// method's are `InputMethodBuildSettingsTests`' and `InputMethodPlistTests`'.
/// [LAW:one-source-of-truth]
///
/// Read off the project xcodegen generates, as `InputMethodBuildSettingsTests` reads it and
/// for its reason: the identifier lives in the build setting, and the plist holds only the
/// setting's name.
@Suite struct ProjectIdentityTests {
    /// The build settings of every configuration of every target that builds an
    /// application, keyed by nothing: what is asked below is asked of all of them.
    private static func bundleConfigurations() throws -> [[String: String]] {
        let url = repository.appending(path: "LowTalker.xcodeproj/project.pbxproj")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "LowTalker.xcodeproj has not been generated; run `make test`, which runs xcodegen - `swift test` alone does not")
        let project = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        let objects = try #require(project["objects"] as? [String: Any])
        return objects.values
            .compactMap { $0 as? [String: Any] }
            .filter { $0["isa"] as? String == "XCBuildConfiguration" }
            .compactMap { $0["buildSettings"] as? [String: Any] }
            .map { $0.compactMapValues { $0 as? String } }
            .filter { $0["PRODUCT_BUNDLE_IDENTIFIER"] != nil }
    }

    /// One app and one input method, and nothing else: a second bundle under a name of its
    /// own is a second installation, which is what a build must not be able to make.
    @Test func theProjectBuildsOneAppAndItsInputMethodAndNothingElse() throws {
        let identifiers = try Self.bundleConfigurations().compactMap { $0["PRODUCT_BUNDLE_IDENTIFIER"] }
        #expect(Set(identifiers) == [AppIdentity.bundleIdentifier, AppIdentity.inputMethodBundleIdentifier])
    }

    /// The name every dialog, list and the menu bar put in front of a person.
    @Test func theAppIsBuiltUnderItsNames() throws {
        let mine = try Self.bundleConfigurations().filter { $0["PRODUCT_BUNDLE_IDENTIFIER"] == AppIdentity.bundleIdentifier }
        try #require(!mine.isEmpty)
        for settings in mine {
            #expect(settings["PRODUCT_NAME"] == AppIdentity.displayName)
            #expect(settings["INFOPLIST_KEY_CFBundleDisplayName"] == AppIdentity.displayName)
        }
    }

    /// Nothing an xcodebuild invocation can pass chooses a name: no identifier or product
    /// name is spelled through a setting a build could override, so a development build
    /// and a release build of one commit are the same bundle.
    @Test func noNameIsChosenByABuildSetting() throws {
        for settings in try Self.bundleConfigurations() {
            for key in ["PRODUCT_BUNDLE_IDENTIFIER", "PRODUCT_NAME", "INFOPLIST_KEY_CFBundleDisplayName"] {
                let value = try #require(settings[key], "a bundle's configuration sets no \(key)")
                #expect(!value.contains("$"), "\(key) is \(value), which a build setting decides")
            }
        }
    }
}
