import Foundation
import Identity
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The menu opens the notices at a path project.yml's build script writes them to. If the
/// two parted, the build would still carry the notices and the menu item would open nothing,
/// and `swift test` would not notice: the app is not part of it.
@Suite struct CarriedNoticesTests {
    @Test func theAppOpensTheNoticesWhereTheBuildWritesThem() throws {
        let yaml = try String(contentsOf: repository.appending(path: "project.yml"), encoding: .utf8)
        let settings = yaml.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("NOTICES_RESOURCE:") }
        #expect(settings == ["NOTICES_RESOURCE: \(Notices.resource)"])
    }
}
