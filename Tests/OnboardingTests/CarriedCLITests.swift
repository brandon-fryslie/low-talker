import Foundation
import Onboarding
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The app names its carried CLI by a path project.yml decides. If the embed moved and
/// this did not, the menu would print an install command for a file that is not there,
/// and nothing that builds under `swift test` would notice: the app is not part of it.
@Suite struct CarriedCLITests {
    @Test func theAppNamesTheCLIWhereProjectYmlPutsIt() throws {
        let yaml = try String(contentsOf: repository.appending(path: "project.yml"), encoding: .utf8)
        // The embed: `- target: lowtalker-cli` followed by its copy block's subpath.
        let embed = try #require(yaml.range(of: "- target: lowtalker-cli\n"), "project.yml embeds no lowtalker-cli")
        let subpath = try #require(yaml[embed.upperBound...].split(separator: "\n").lazy
            .compactMap { $0.split(separator: "subpath: ", maxSplits: 1).dropFirst().first }.first)
        // The product's name, from the target's own settings.
        let target = try #require(yaml.range(of: "\n  lowtalker-cli:\n"), "project.yml declares no lowtalker-cli target")
        let product = try #require(yaml[target.upperBound...].split(separator: "\n").lazy
            .compactMap { $0.split(separator: "PRODUCT_NAME: ", maxSplits: 1).dropFirst().first }.first)
        #expect("\(subpath)/\(product)" == CarriedCLI.pathInBundle)
    }
}
