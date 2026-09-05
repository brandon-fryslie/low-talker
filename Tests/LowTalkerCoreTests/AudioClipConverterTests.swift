import AVFoundation
import LowTalkerCore
import Testing

/// A 440 Hz tone rendered at 48 kHz stereo, the shape a typical microphone hands
/// the tap. The contract is that the pipeline sees one continuous 16 kHz tone no
/// matter how the source was chunked.
@Suite struct AudioClipConverterTests {
    static let source = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    static let sourceFrames = 48_000
    static let expectedSamples = 16_000

    static func tone(from start: Int, frames: Int) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            let value = Float(sin(2 * Double.pi * 440 * Double(start + i) / source.sampleRate))
            buffer.floatChannelData![0][i] = value
            buffer.floatChannelData![1][i] = value
        }
        return buffer
    }

    static func convert(chunk: Int) throws -> [Float] {
        let converter = try AudioClip.Converter(from: source)
        var samples: [Float] = []
        for start in stride(from: 0, to: sourceFrames, by: chunk) {
            samples += try converter.convert(tone(from: start, frames: min(chunk, sourceFrames - start)))
        }
        return samples
    }

    /// Mean distance from the ideal 16 kHz tone, past the resampler's warm-up.
    static func error(in samples: [Float]) -> Double {
        let window = 200..<(samples.count - 100)
        let total = window.reduce(0.0) { sum, i in
            sum + abs(Double(samples[i]) - sin(2 * Double.pi * 440 * Double(i) / AudioClip.sampleRate))
        }
        return total / Double(window.count)
    }

    /// Every chunk size a tap or a file loader hands over, including the 100 ms tap
    /// buffers that are larger than one converter ask: no chunking loses samples,
    /// holds them back for a later call, or leaves a seam in the tone.
    @Test(arguments: [480, 4_096, 4_410, 4_800, 48_000])
    func chunkingIsInaudible(chunk: Int) throws {
        let samples = try Self.convert(chunk: chunk)
        #expect(abs(samples.count - Self.expectedSamples) <= 64)
        #expect(Self.error(in: samples) < 1e-3)
    }

    @Test func chunkedStreamMatchesWholeStream() throws {
        let chunked = try Self.convert(chunk: 480)
        let whole = try Self.convert(chunk: Self.sourceFrames)
        #expect(chunked.count == whole.count)
        let difference = zip(chunked, whole).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        #expect(difference < 1e-4)
    }

    @Test func drainReleasesTheResamplerTail() throws {
        let converter = try AudioClip.Converter(from: Self.source)
        let streamed = try converter.convert(Self.tone(from: 0, frames: Self.sourceFrames))
        let tail = try converter.drain()
        #expect(tail.count <= 16, "only the resampler's own delay waits for the drain")
        #expect(abs(streamed.count + tail.count - Self.expectedSamples) <= 2)
    }

    @Test func rejectsAFormatWithNoConversionPath() {
        let silent = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 0)
        // A zero-channel format is what an input node reports with no device attached;
        // the SDK may refuse to build it at all, and either refusal is the contract.
        #expect(throws: (any Error).self) {
            try AudioClip.Converter(from: try #require(silent))
        }
    }
}
