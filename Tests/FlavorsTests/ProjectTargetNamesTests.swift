import Foundation
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// No two targets in project.yml share a name once case is ignored.
///
/// Xcode keeps each target's intermediates in a folder named for the target, and this Mac's
/// volume, like every default macOS volume, is case-insensitive. Two targets that differ
/// only in case build into one folder and link each other's objects without an error:
/// measured, a CLI target named `lowtalker` beside the release app's `LowTalker` left the
/// release app linked from the CLI's entry and carrying no AppDelegate. CI builds only the
/// development app, so nothing else would notice. [LAW:no-silent-failure]
@Suite struct ProjectTargetNamesTests {
    /// The names declared directly under `targets:`, two spaces in, which is where xcodegen
    /// reads them from.
    private static func targetNames() throws -> [String] {
        let yaml = try String(contentsOf: repository.appending(path: "project.yml"), encoding: .utf8)
        let section = try #require(yaml.components(separatedBy: "\ntargets:\n").dropFirst().first)
        return section.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("  "), !line.hasPrefix("   "), line.hasSuffix(":") else { return nil }
            return String(line.dropFirst(2).dropLast())
        }
    }

    @Test func everyTargetHasAFolderOfItsOwn() throws {
        let names = try Self.targetNames()
        #expect(names.contains("LowTalker"), "read no targets out of project.yml: \(names)")
        let folded = Dictionary(grouping: names, by: { $0.lowercased() })
        #expect(folded.values.filter { $0.count > 1 }.isEmpty, "targets sharing a folder: \(folded.values.filter { $0.count > 1 })")
    }
}
