import AVFoundation

extension AudioClip {
    /// Converts a stream of buffers in one source format into pipeline samples.
    ///
    /// One instance per stream: the resampler carries its state between calls so a
    /// chunk boundary is inaudible, and `drain` releases the tail once the stream
    /// ends. The microphone tap and the file loader are the two streams; nothing
    /// else resamples.
    ///
    /// Calls are serialized by the caller. Not Sendable: it holds AVFoundation objects
    /// the macOS 15 SDK does not mark Sendable, so the tap captures it as
    /// `nonisolated(unsafe)` and is its only caller.
    public final class Converter {
        private let converter: AVAudioConverter
        /// What the converter is handed per ask, in the source format. Sized to the
        /// most it has been seen to ask for at once (4096 frames), so a tap buffer
        /// takes one or two asks; a smaller size would only mean more asks.
        private let piece: AVAudioPCMBuffer
        /// What the converter fills per call, in the pipeline format.
        private let scratch: AVAudioPCMBuffer

        public init(from source: AVAudioFormat) throws {
            guard let converter = AVAudioConverter(from: source, to: AudioClip.format) else {
                throw AudioClipError.unconvertibleFormat(sampleRate: source.sampleRate, channels: source.channelCount)
            }
            // Without this, extra source channels are discarded rather than mixed; the
            // right-only fixture loads as silence.
            converter.downmix = true
            guard let piece = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4_096),
                  let scratch = AVAudioPCMBuffer(pcmFormat: AudioClip.format, frameCapacity: 16_384)
            else {
                throw AudioClipError.bufferAllocationFailed
            }
            self.converter = converter
            self.piece = piece
            self.scratch = scratch
        }

        /// The pipeline samples for the whole of `input`.
        public func convert(_ input: AVAudioPCMBuffer) throws -> [Float] {
            try pull(input, then: .noDataNow)
        }

        /// The resampler's tail. The stream is over; convert nothing more after this.
        public func drain() throws -> [Float] {
            try pull(nil, then: .endOfStream)
        }

        private func pull(_ input: AVAudioPCMBuffer?, then exhausted: AVAudioConverterInputStatus) throws -> [Float] {
            // The converter asks for a packet count per ask and holds any surplus it is
            // handed until the next call; handed a whole 100 ms tap buffer, it returns
            // up to 90 ms of it late. Serving each ask no more than it asked for, from a
            // cursor over the input, leaves nothing held: every call returns all of its
            // input, and only the resampler's few-sample tail waits for `drain`.
            // [LAW:no-shared-mutable-globals] exception: the SDK types the block
            // @Sendable, but `convert` calls it synchronously on this thread, so nothing
            // is shared. A Mutex would satisfy the annotation only where AVAudioFormat
            // is Sendable (macOS 26 SDK); on the macOS 15 SDK the buffers share a region
            // with the converter and cannot be sent into one.
            nonisolated(unsafe) let input = input
            nonisolated(unsafe) let piece = piece
            nonisolated(unsafe) var cursor = 0
            var samples: [Float] = []
            while true {
                var conversionError: NSError?
                let status = converter.convert(to: scratch, error: &conversionError) { asked, inputStatus in
                    guard let input, cursor < Int(input.frameLength) else {
                        inputStatus.pointee = exhausted
                        return nil
                    }
                    let frames = min(Int(input.frameLength) - cursor, Int(asked), Int(piece.frameCapacity))
                    piece.fill(from: input, offset: cursor, frames: frames)
                    cursor += frames
                    inputStatus.pointee = .haveData
                    return piece
                }
                switch status {
                case .haveData, .inputRanDry, .endOfStream:
                    // Standard float format guarantees channel data; channel 0 is the only channel.
                    samples.append(contentsOf: UnsafeBufferPointer(start: scratch.floatChannelData![0], count: Int(scratch.frameLength)))
                    // `.haveData` means the scratch buffer filled before the input ran out.
                    if status != .haveData { return samples }
                case .error:
                    throw AudioClipError.conversionFailed(underlying: conversionError)
                @unknown default:
                    throw AudioClipError.conversionFailed(underlying: conversionError)
                }
            }
        }
    }
}

private extension AVAudioPCMBuffer {
    /// Becomes `frames` frames of `source` starting at `offset`, whatever the sample
    /// layout: each channel buffer is copied at its own byte stride.
    func fill(from source: AVAudioPCMBuffer, offset: Int, frames: Int) {
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let sources = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        for (from, to) in zip(sources, UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)) {
            to.mData!.copyMemory(from: from.mData! + offset * bytesPerFrame, byteCount: frames * bytesPerFrame)
        }
        frameLength = AVAudioFrameCount(frames)
    }
}
