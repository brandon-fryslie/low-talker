import AVFoundation
import Synchronization

/// The pipeline's audio currency: 16 kHz mono Float32 samples.
///
/// [LAW:types-are-the-program] The sample rate is a constant on the type, not a
/// field. A clip at any other rate or channel count is unrepresentable, so the ring
/// buffer, the transcribers, and the latency harness never ask what format they hold.
public struct AudioClip: Sendable, Equatable {
    public static let sampleRate: Double = 16_000

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
    /// More frames than a single AVFoundation buffer can hold.
    case fileTooLong(frames: Int64)
    /// AVFoundation has no conversion path from the file's format to 16 kHz mono.
    case unconvertibleFormat(sampleRate: Double, channels: UInt32)
    /// The converter accepted the format pair but failed mid-stream; AVFoundation may
    /// or may not attach a reason.
    case conversionFailed(underlying: (any Error)?)
    case bufferAllocationFailed

    public var description: String {
        switch self {
        case .unreadable(let url, let underlying):
            "cannot read audio file \(url.path): \(underlying)"
        case .fileTooLong(let frames):
            "audio file has \(frames) frames; at most \(AVAudioFrameCount.max) can be loaded"
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
    static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

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
            throw AudioClipError.fileTooLong(frames: file.length)
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

        guard let converter = AVAudioConverter(from: source, to: Self.format) else {
            throw AudioClipError.unconvertibleFormat(sampleRate: source.sampleRate, channels: source.channelCount)
        }
        // Without this, extra source channels are discarded rather than mixed; the
        // right-only fixture loads as silence.
        converter.downmix = true
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: 16_384) else {
            throw AudioClipError.bufferAllocationFailed
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(input.frameLength) * Self.sampleRate / source.sampleRate) + 1)
        // The converter's input block is @Sendable, so the "handed over yet?" fact needs
        // an owner rather than a captured var. [LAW:no-shared-mutable-globals] The mutex
        // is that owner: the block takes the buffer exactly once, then reports end of
        // stream while the converter drains its resampler tail. `.endOfStream` is the only exit.
        let pending = Mutex<AVAudioPCMBuffer?>(input)
        drain: while true {
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                let next = pending.withLock { buffer -> AVAudioPCMBuffer? in
                    let taken = buffer
                    buffer = nil
                    return taken
                }
                inputStatus.pointee = next == nil ? .endOfStream : .haveData
                return next
            }
            switch status {
            case .haveData, .inputRanDry, .endOfStream:
                // Standard float format guarantees channel data; channel 0 is the only channel.
                samples.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
                if status == .endOfStream { break drain }
            case .error:
                throw AudioClipError.conversionFailed(underlying: conversionError)
            @unknown default:
                throw AudioClipError.conversionFailed(underlying: conversionError)
            }
        }
        self.init(samples: samples)
    }
}
