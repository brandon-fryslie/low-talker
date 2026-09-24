import Foundation
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Every bundle's version comes from one place, project.yml's two settings.
///
/// Held here on what xcodegen writes: each generated Info.plist names the settings rather
/// than a version of its own, and every build configuration the project resolves sets both.
/// What ships is held by the build itself - the post-build step "The bundle carries the
/// version project.yml sets" fails `make app` when a bundle's plist does not match - since
/// no test sees a shipped bundle. [LAW:single-enforcer] Each of the two checks one thing.
///
/// Read off the generated files, which `make test` writes first; `swift test` alone does
/// not. [LAW:effects-at-boundaries]
@Suite struct BundleVersionTests {
    private static func generatedPlists() throws -> [URL] {
        let folder = repository.appending(path: "App/Generated")
        let plists = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("-Info.plist") }
        try #require(!plists.isEmpty, "no Info.plist under App/Generated; run `make test`, which runs xcodegen")
        return plists
    }

    /// Each plist defers to the settings. A literal here is a second version, and the one
    /// xcodegen writes by default - 1.0 - is not the one any bundle ships.
    @Test func everyGeneratedPlistTakesItsVersionFromTheSettings() throws {
        for url in try Self.generatedPlists() {
            let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
            #expect(plist["CFBundleShortVersionString"] as? String == "$(MARKETING_VERSION)", "\(url.lastPathComponent)")
            #expect(plist["CFBundleVersion"] as? String == "$(CURRENT_PROJECT_VERSION)", "\(url.lastPathComponent)")
        }
    }

    /// The project sets both, once, for every configuration: the version a person reads,
    /// and a build number that is a whole number, since that is what an updater compares.
    @Test func theProjectSetsBothForEveryConfiguration() throws {
        let url = repository.appending(path: "LowTalker.xcodeproj/project.pbxproj")
        let project = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        let objects = try #require(project["objects"] as? [String: Any])
        let rootID = try #require(project["rootObject"] as? String)
        let root = try #require(objects[rootID] as? [String: Any])
        let listID = try #require(root["buildConfigurationList"] as? String)
        let list = try #require(objects[listID] as? [String: Any])
        let configurations = try #require(list["buildConfigurations"] as? [String])
        try #require(!configurations.isEmpty)
        for id in configurations {
            let settings = try #require((objects[id] as? [String: Any])?["buildSettings"] as? [String: Any])
            #expect((settings["MARKETING_VERSION"] as? String)?.isEmpty == false)
            #expect((settings["CURRENT_PROJECT_VERSION"] as? String).flatMap(Int.init) != nil)
        }
    }
}
