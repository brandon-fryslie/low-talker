import Foundation
import LowTalkerCore
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The bundle's container migration moves a pre-sandbox config to the path the app reads.
///
/// project.yml writes that destination as a build setting, because xcodegen cannot read
/// Swift. A copy that drifted would move the file somewhere the app never looks, and an
/// upgrade would run on the defaults without a word. [LAW:one-source-of-truth]
@Suite struct ContainerMigrationTests {
    @Test func theMigrationMovesTheConfigToThePathTheAppReads() throws {
        let yaml = try String(contentsOf: repository.appending(path: "project.yml"), encoding: .utf8)
        let setting = yaml.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("CONFIG_IN_CONTAINER:") else { return nil }
            return trimmed.dropFirst("CONFIG_IN_CONTAINER:".count).trimmingCharacters(in: .whitespaces)
        }
        #expect(setting == [Config.pathInContainer])
    }
}
