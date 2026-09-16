import Foundation
import LowTalkerCore
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A release carries its model in the bundle's resources, and the app installs out of the
/// store it finds there.
@Suite struct CarriedModelStoreTests {
    /// A bundle on disk holding `resources`, each a folder under `Contents/Resources`.
    struct FakeApp: ~Copyable {
        let url: URL

        init(resources: [String]) throws {
            url = FileManager.default.temporaryDirectory.appending(path: "CarriedModelStoreTests-\(UUID().uuidString).app")
            let contents = url.appending(path: "Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": "test.carried.\(UUID().uuidString)", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
            for resource in resources {
                try FileManager.default.createDirectory(at: contents.appending(components: "Resources", resource, "installed"), withIntermediateDirectories: true)
            }
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    /// xcodegen cannot read the Swift constant, so project.yml names the folder again for
    /// the build script that copies the store in. Were the two to differ, a release would
    /// carry its model under a name the app never looks for and download it anyway, and
    /// nothing short of a first launch with the network off would say so.
    @Test func theProjectCarriesTheStoreWhereTheAppLooks() throws {
        let yaml = try String(contentsOf: repository.appending(path: "project.yml"), encoding: .utf8)
        let settings = yaml.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("MODEL_STORE_RESOURCE:") }
        #expect(settings == ["MODEL_STORE_RESOURCE: \(ModelStore.carriedResourceName)"])
    }

    @Test func aBundleCarryingAStoreHandsItOver() throws {
        let app = try FakeApp(resources: [ModelStore.carriedResourceName])
        let bundle = try #require(Bundle(url: app.url))
        let carried = try #require(ModelStore.carried(by: bundle))
        #expect(carried.directory.resolvingSymlinksInPath() == app.url.appending(components: "Contents", "Resources", ModelStore.carriedResourceName).resolvingSymlinksInPath())
    }

    @Test func aBundleCarryingNoStoreHandsNothingOver() throws {
        let app = try FakeApp(resources: ["something-else"])
        let bundle = try #require(Bundle(url: app.url))
        #expect(ModelStore.carried(by: bundle) == nil)
    }
}
