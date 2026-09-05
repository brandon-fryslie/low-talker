import AVFoundation

/// The pipeline's audio currency: 16 kHz mono Float32 samples.
///
/// [LAW:types-are-the-program] The sample rate is a constant on the type, not a
/// field. A clip at any other rate or channel count is unrepresentable, so the ring
/// buffer, the transcribers, and the latency harness never ask what format they hold.
public struct AudioClip: Sendable, Equatable {
    public static let sampleRate: Double = 16_000

    /// The samples `duration` spans at the pipeline rate, to the nearest sample.
    /// [LAW:one-source-of-truth] The one place seconds become sample counts, so a
    /// ring's capacity and a session's pre-roll are measured by the same rule.
    public static func sampleCount(for duration: TimeInterval) -> Int {
        Int((duration * sampleRate).rounded())
    }

    public let samples: [Float]

    public init(samples: [Float]) {
        self.samples = samples
    }

    public var duration: TimeInterval {
        Double(samples.count) / Self.sampleRate
    }

    /// Largest absolute sample value; zero for silence.
    public var peak: Float {
        samples.reduce(0) { max($0, abs($1)) }
    }
}

public enum AudioClipError: Error, CustomStringConvertible {
    /// AVFoundation could not open the file; the CoreAudio error is attached.
    case unreadable(URL, underlying: any Error)
    /// AVFoundation could not create or fill the file; the CoreAudio error is attached.
    case unwritable(URL, underlying: any Error)
    /// More frames than a single AVFoundation buffer can hold.
    case tooLong(frames: Int64)
    /// AVFoundation has no conversion path from the source format to 16 kHz mono.
    case unconvertibleFormat(sampleRate: Double, channels: UInt32)
    /// The converter accepted the format pair but failed mid-stream; AVFoundation may
    /// or may not attach a reason.
    case conversionFailed(underlying: (any Error)?)
    case bufferAllocationFailed

    public var description: String {
        switch self {
        case .unreadable(let url, let underlying):
            "cannot read audio file \(url.path): \(underlying)"
        case .unwritable(let url, let underlying):
            "cannot write audio file \(url.path): \(underlying)"
        case .tooLong(let frames):
            "\(frames) frames; a single audio buffer holds at most \(AVAudioFrameCount.max)"
        case .unconvertibleFormat(let sampleRate, let channels):
            "no conversion from \(sampleRate) Hz, \(channels) channel(s) to \(AudioClip.sampleRate) Hz mono"
        case .conversionFailed(let underlying):
            "audio conversion failed: \(underlying.map { "\($0)" } ?? "no detail from AVFoundation")"
        case .bufferAllocationFailed:
            "could not allocate an audio buffer"
        }
    }
}

extension AudioClip {
    /// Deinterleaved Float32 at the pipeline rate. `standardFormat` never fails for a
    /// positive rate and channel count, so the unwrap is a static fact, not a guess.
    /// Computed rather than stored: the macOS 15 SDK does not mark AVAudioFormat
    /// Sendable, so Swift 6 rejects it as a static let there.
    static var format: AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)! }

    /// Load any file AVFoundation can read (wav, aiff, m4a, ...) as a clip.
    ///
    /// [LAW:parse-dont-validate] This is the one boundary where file audio of any
    /// rate and channel count becomes a clip. Resampling and downmixing happen here,
    /// once; nothing downstream sees anything but 16 kHz mono.
    public init(contentsOf url: URL) throws {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioClipError.unreadable(url, underlying: error)
        }
        let source = file.processingFormat
        guard let frameCount = AVAudioFrameCount(exactly: file.length) else {
            throw AudioClipError.tooLong(frames: file.length)
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frameCount) else {
            throw AudioClipError.bufferAllocationFailed
        }
        // [LAW:dataflow-not-control-flow] exception: AVAudioFile refuses a zero-frame
        // read (fails with no error attached), so the empty file is hemmed here at the
        // foreign edge; an empty file is a legal empty clip, not a failure.
        if file.length > 0 {
            do {
                try file.read(into: input)
            } catch {
                throw AudioClipError.unreadable(url, underlying: error)
            }
        }
        let converter = try Converter(from: source)
        self.init(samples: try converter.convert(input) + converter.drain())
    }

    /// Write as a 16-bit PCM wav at the pipeline rate, the encoding every player and
    /// engine loader accepts. The inverse of `init(contentsOf:)` up to 16-bit rounding.
    public func write(to url: URL) throws {
        guard let frameCount = AVAudioFrameCount(exactly: samples.count) else {
            throw AudioClipError.tooLong(frames: Int64(samples.count))
        }
        // A zero-capacity buffer allocates no channel memory and its channel pointer
        // is NULL; one spare frame keeps the pointer valid when the clip is empty.
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: max(frameCount, 1)) else {
            throw AudioClipError.bufferAllocationFailed
        }
        // Standard float format guarantees channel data; channel 0 is the only channel.
        _ = UnsafeMutableBufferPointer(start: buffer.floatChannelData![0], count: samples.count).update(fromContentsOf: samples)
        buffer.frameLength = frameCount

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Self.format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
            file.close()
        } catch {
            throw AudioClipError.unwritable(url, underlying: error)
        }
    }
}
