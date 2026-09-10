import AVFoundation
@testable import LowTalkerCore
import Testing

@Suite struct AudioHardwareTests {
    /// A CoreAudio stamp counts the machine's raw ticks. Stated against
    /// `hostTime(forSeconds:)`, the inverse of what the parse calls, so the claim is
    /// the contract rather than the arithmetic.
    @Test func aStampInHostTicksBecomesTheSecondsItStandsFor() throws {
        let parsed = try HostTime(AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 1.5)))
        #expect(parsed.uptime == .seconds(1.5))
    }

    /// AVFoundation may hand out a time placed only among samples. Nothing can say when
    /// those were captured, so the buffer fails the engine rather than being guessed at.
    @Test func aTimeWithNoHostClockBehindItIsRefused() {
        let placedOnlyAmongSamples = AVAudioTime(sampleTime: 4410, atRate: 44100)
        #expect(throws: AudioHardwareError.bufferWithoutTime) { try HostTime(placedOnlyAmongSamples) }
    }
}
