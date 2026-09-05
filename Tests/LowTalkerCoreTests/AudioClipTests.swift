import Foundation
import LowTalkerCore
import Testing

private func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Fixtures"))
}

/// Both fixtures are the same utterance rendered by `say`, then encoded at 16 kHz
/// mono and at 44.1 kHz stereo. The contract under test is that the source encoding
/// is invisible past the load boundary: same speech, same clip.
@Suite struct AudioClipTests {
    static let fixtureDuration: TimeInterval = 2.2585

    @Test(arguments: ["hello-16k-mono", "hello-44k-stereo"])
    func loadsAnyEncodingAsSixteenKilohertzMono(name: String) throws {
        let clip = try AudioClip(contentsOf: fixture(name))
        #expect(abs(clip.duration - Self.fixtureDuration) < 0.01)
        #expect(clip.peak > 0.05, "fixture should contain speech, not silence")
    }

    @Test func durationIsSampleCountAtSixteenKilohertz() {
        let clip = AudioClip(samples: Array(repeating: 0, count: 16_000))
        #expect(clip.duration == 1)
        #expect(clip.peak == 0)
    }

    /// The same tone in the left channel only and in the right channel only. A
    /// downmix that dropped or favored either channel could not produce equal peaks.
    @Test func downmixHearsBothChannelsEqually() throws {
        let left = try AudioClip(contentsOf: fixture("tone-left-only"))
        let right = try AudioClip(contentsOf: fixture("tone-right-only"))
        #expect(left.peak > 0.1)
        #expect(abs(left.peak - right.peak) < 0.001)
        #expect(abs(left.duration - 1) < 0.01)
    }

    @Test func emptyFileIsAnEmptyClip() throws {
        let clip = try AudioClip(contentsOf: fixture("empty"))
        #expect(clip.samples.isEmpty)
        #expect(clip.duration == 0)
    }

    @Test func missingFileFailsLoudly() {
        #expect(throws: (any Error).self) {
            try AudioClip(contentsOf: URL(fileURLWithPath: "/nonexistent/clip.wav"))
        }
    }
}
