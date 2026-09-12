import ArgumentParser
import Flavors
import Foundation
import LowTalkerCore
import Testing
@testable import lowtalker

/// What `lowtalker config watch` prints for one reload is its contract: it is the whole
/// of what somebody watching an edit reads, and the only place the difference between a
/// save taken up and a save turned away is ever said out loud. `ConfigWatchTests` pins
/// which `Reload` a reading produces; these pin what that reload reads as.
@Suite struct ConfigWatchCommandTests {
    /// A Mac with nothing installed, so what the report says is the same on every
    /// machine that runs these.
    static func noApps(_: BundleID) -> Bool { false }

    /// The release copy throughout, because `file` is the release copy's own path: a
    /// reading that named one and was read as the other is the mismatch these types now
    /// make unrepresentable, and a test should not be the one place it is spelled.
    static let flavor = Flavor.release
    /// Spelled out rather than taken from `Config.fileURL(for:)`, for the reason `noApps`
    /// exists: a literal reads the same on every machine, where the real path carries
    /// whoever's home directory ran the suite. It is the release copy's file name.
    static let file = URL(filePath: "/Users/someone/.config/low-talker/config.toml")

    static func running() throws -> Config.Loaded {
        .file(
            try Config(toml: """
                [[modes]]
                name = "dictation"
                chord = { modifiers = ["rightOption"] }
                """, flavor: flavor),
            at: file,
            flavor: flavor
        )
    }

    /// A save that was taken up reads as the report `check` prints, so the file in force
    /// is described one way whether it is asked about once or watched all afternoon.
    @Test func aConfigTakenUpReadsAsTheReport() throws {
        let narration = ConfigCommand.Watch.narration(
            of: .adopted(try Self.running()), appExists: Self.noApps
        )

        #expect(narration.hasPrefix("\n"), "a blank line opens each report, so a run of them reads as several")
        #expect(narration.contains(Self.file.path), "the report names the file it read")
        #expect(narration.contains("dictation"), "the report names what would run")
    }

    /// Deleting the file is a reload like any other, and it says the file is gone rather
    /// than printing the defaults as though somebody had written them.
    @Test func aDeletedFileReadsAsTheDefaultsAndSaysSo() {
        let narration = ConfigCommand.Watch.narration(
            of: .adopted(.noFile(at: Self.file, flavor: Self.flavor)), appExists: Self.noApps
        )

        #expect(narration.contains(Self.file.path))
        #expect(narration.contains("defaults"))
    }

    /// The order is the contract, not an accident of how the two lines were written: the
    /// error is the news and comes first, and what is still running is the reassurance
    /// and comes second. Swapping them changes what the line means to a reader mid-edit.
    @Test func aRefusedSaveNamesTheErrorFirstAndWhatIsStillRunningSecond() throws {
        let running = try Self.running()
        let lines = ConfigCommand.Watch.narration(
            of: .kept(running, because: .unknownKeys(["modle"])), appExists: Self.noApps
        ).components(separatedBy: "\n")

        #expect(lines.count == 3)
        #expect(lines[0] == "", "a blank line opens a refusal too")
        #expect(lines[1].hasPrefix("refused: "))
        #expect(lines[1].contains("modle"), "the refusal names what was wrong with the save")
        #expect(lines[2].hasPrefix("still running: "))
        #expect(lines[2].contains(Self.file.path), "and the config that goes on running")
    }

    /// [LAW:no-silent-failure] A config that cannot be read at startup has no previous
    /// config to keep, so `watch` refuses to start at all - with the error that says why,
    /// the way `check` refuses - rather than coming up quietly on the defaults and
    /// watching for a file it never understood.
    @Test(.timeLimit(.minutes(1)))
    func aFileThatCannotBeUnderstoodNeverStartsAWatch() async throws {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "low-talker-\(UUID().uuidString).toml")
        try #"modle = "base.en""#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let watch = try ConfigCommand.Watch.parse(["--path", url.path])
        await #expect(throws: ConfigError.unknownKeys(["modle"])) { try await watch.run() }
    }
}
