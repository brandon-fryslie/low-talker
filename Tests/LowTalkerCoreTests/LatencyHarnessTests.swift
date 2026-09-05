import Foundation
import LowTalkerCore
import Testing

/// A bench directory built on the fly: a clip the pipeline wrote beside the text
/// it is claimed to say.
private final class BenchDirectory {
    let url: URL
    static let tone = AudioClip(samples: (0..<1_600).map { Float(sin(2 * Double.pi * 440 * Double($0) / AudioClip.sampleRate)) })

    init(under base: URL = FileManager.default.temporaryDirectory) throws {
        url = base.appending(path: "lowtalker-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// `name` may carry a folder, such as `say/greeting`.
    func add(_ name: String, text: String?, wav: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.appending(path: name).deletingLastPathComponent(), withIntermediateDirectories: true)
        if wav { try Self.tone.write(to: url.appending(path: "\(name).wav")) }
        if let text { try text.write(to: url.appending(path: "\(name).txt"), atomically: true, encoding: .utf8) }
    }
}

/// A case-sensitive volume, the only place `foo.wav` and `foo.WAV` can both exist:
/// APFS as shipped stores them as one file, so the temp directory cannot host them.
private final class CaseSensitiveVolume {
    let mountPoint: URL
    private let image: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "lowtalker-cs-\(UUID().uuidString)")
        image = base.appendingPathExtension("dmg")
        mountPoint = base
        try Self.hdiutil("create", "-size", "8m", "-fs", "Case-sensitive APFS", "-volname", "lowtalker-cs", "-quiet", image.path)
        try Self.hdiutil("attach", image.path, "-mountpoint", mountPoint.path, "-nobrowse", "-quiet")
    }

    deinit {
        try? Self.hdiutil("detach", mountPoint.path, "-quiet")
        try? FileManager.default.removeItem(at: image)
    }

    private static func hdiutil(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HdiutilFailed(arguments: arguments, status: process.terminationStatus)
        }
    }

    struct HdiutilFailed: Error {
        let arguments: [String]
        let status: Int32
    }
}

@Suite struct FixtureTests {
    /// Pairs anywhere under the directory, named by their path from it.
    @Test func loadsEveryPairByName() throws {
        let bench = try BenchDirectory()
        try bench.add("zeta", text: "Last one.")
        try bench.add("say/alpha", text: "Hello, world.")
        let fixtures = try Fixture.load(directory: bench.url)
        #expect(fixtures.map(\.name) == ["say/alpha", "zeta"])
        #expect(fixtures[0].reference.words == ["hello", "world"])
        // 16-bit PCM rounds each sample, so the clip is compared by length, not value.
        #expect(fixtures[0].clip.samples.count == BenchDirectory.tone.samples.count)
    }

    /// An uppercase extension is the same file kind, not a file to skip.
    @Test func anUppercaseExtensionStillPairs() throws {
        let bench = try BenchDirectory()
        try bench.add("loud", text: "Loud.", wav: false)
        try BenchDirectory.tone.write(to: bench.url.appending(path: "loud.WAV"))
        let fixtures = try Fixture.load(directory: bench.url)
        #expect(fixtures.map(\.name) == ["loud"])
        #expect(fixtures[0].reference.words == ["loud"])
    }

    @Test func twoSpellingsOfOneClipAreRefused() throws {
        let volume = try CaseSensitiveVolume()
        let bench = try BenchDirectory(under: volume.mountPoint)
        try bench.add("echo", text: "Echo.")
        try BenchDirectory.tone.write(to: bench.url.appending(path: "echo.WAV"))
        do {
            _ = try Fixture.load(directory: bench.url)
            Issue.record("two spellings of one clip loaded as a fixture")
        } catch FixtureError.twoOfAKind(let name, let first, let second) {
            #expect(name == "echo")
            #expect(Set([first.lastPathComponent, second.lastPathComponent]) == ["echo.wav", "echo.WAV"])
        }
    }

    @Test func aClipWithoutItsWordsIsRefused() throws {
        let bench = try BenchDirectory()
        try bench.add("mute", text: nil)
        #expect(throws: FixtureError.halfAFixture(name: "mute", directory: bench.url, missing: "txt")) {
            try Fixture.load(directory: bench.url)
        }
    }

    @Test func wordsWithoutTheirClipAreRefused() throws {
        let bench = try BenchDirectory()
        try bench.add("unspoken", text: "Never recorded.", wav: false)
        #expect(throws: FixtureError.halfAFixture(name: "unspoken", directory: bench.url, missing: "wav")) {
            try Fixture.load(directory: bench.url)
        }
    }

    @Test func aReferenceWithNoWordsIsRefused() throws {
        let bench = try BenchDirectory()
        try bench.add("blank", text: " ... ")
        #expect(throws: FixtureError.referenceSaysNothing(name: "blank")) {
            try Fixture.load(directory: bench.url)
        }
    }

    @Test func anEmptyDirectoryIsAnError() throws {
        let bench = try BenchDirectory()
        #expect(throws: FixtureError.noFixtures(directory: bench.url)) {
            try Fixture.load(directory: bench.url)
        }
    }
}

/// An engine that hears the same thing every time, so the harness's bookkeeping
/// can be checked without weights.
private struct FixedEar: Transcriber {
    let heard: String
    func transcribe(_ clip: AudioClip) async throws -> Transcript {
        Transcript(typed: heard)
    }
}

@Suite struct LatencyHarnessTests {
    static func fixture(_ name: String, says text: String) throws -> Fixture {
        try Fixture(name: name, clip: BenchDirectory.tone, reference: text)
    }

    @Test func loadsOnceAndScoresEveryFixture() async throws {
        let fixtures = [
            try Self.fixture("exact", says: "see you at noon"),
            try Self.fixture("close", says: "see me at noon soon"),
        ]
        var loads = 0
        let report = try await LatencyHarness.measure(fixtures, reruns: 2) {
            loads += 1
            return FixedEar(heard: "See you at noon.")
        }
        #expect(loads == 1)
        #expect(report.fixtures.map(\.name) == ["exact", "close"])
        #expect(report.fixtures.map(\.wordErrorRate.errors) == [0, 2])
        #expect(report.fixtures.map(\.laterKeyUpToTranscript.count) == [2, 2])
        #expect(report.fixtures[0].transcript.text == "See you at noon.")
        #expect(report.fixtures[0].audio == BenchDirectory.tone.duration)
    }

    @Test func aSingleRunIsItsOwnMedian() async throws {
        let report = try await LatencyHarness.measure([try Self.fixture("one", says: "hi")], reruns: 0) {
            FixedEar(heard: "hi")
        }
        let result = report.fixtures[0]
        #expect(result.laterKeyUpToTranscript.isEmpty)
        #expect(result.medianKeyUpToTranscript == result.firstKeyUpToTranscript)
    }

    /// An even number of runs reports the lower middle, a wait that happened.
    @Test func medianIsTheLowerMiddleOfEveryRun() {
        let result = LatencyReport.FixtureResult(
            name: "n", audio: 1,
            firstKeyUpToTranscript: .seconds(4),
            laterKeyUpToTranscript: [.seconds(1), .seconds(3), .seconds(2)],
            transcript: Transcript(typed: "n"),
            wordErrorRate: WordErrorRate(reference: SpokenWords("n"), hypothesis: SpokenWords("n"))
        )
        #expect(result.medianKeyUpToTranscript == .seconds(2))
    }
}
