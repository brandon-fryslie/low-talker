import AVFoundation
import Foundation
import LowTalkerCore
import Network
import Synchronization

/// One Realtime transcription socket, from the 101 to the close (epic low-serve-axq): the
/// client's events read in order, each item heard by one streaming `transcribe`, and every
/// server event sent through one outbox.
struct RealtimeSocket {
    let transcriber: any Transcriber

    /// The most one message may hold. Pipecat's appends are about 5 KB of base64 each.
    static let messageLimit = 1 << 20

    /// Serves the socket until the client closes it, breaks the protocol, or is lost, and
    /// says what happened on it.
    func run(_ connection: NWConnection, _ reader: inout Reader) async -> (RealtimeActivity, lost: String?) {
        let (outgoing, outbox) = AsyncStream<Outgoing>.makeStream()
        // [LAW:single-enforcer] The one writer: every frame goes out in the order it was
        // put in the outbox, and is counted once it has gone.
        let writer = Task {
            var sent = RealtimeActivity.Sent()
            for await frame in outgoing {
                do {
                    try await connection.send(frame.bytes)
                } catch {
                    return (sent, "\(error)" as String?)
                }
                sent.count(frame)
            }
            return (sent, nil as String?)
        }
        var activity = RealtimeActivity()
        var lost: String?
        var state = State(session: RealtimeSession(), outbox: Outbox(outbox))
        state.outbox.emit(.sessionCreated(id: state.sessionID, state.session))
        var assembler = WebSocket.Assembler()
        reading: while true {
            let message: WebSocket.Message
            do {
                message = try await reader.message(&assembler, limit: Self.messageLimit)
            } catch let violation as WebSocket.Violation {
                activity.violation = violation.description
                activity.closeCode = Int(violation.code)
                state.outbox.put(.control(WebSocket.close(violation.code, violation.description)))
                break reading
            } catch {
                lost = "\(error)"
                break reading
            }
            switch message {
            case .text(let text):
                state.receive(text, transcriber: transcriber, &activity)
            case .binary:
                let violation = WebSocket.Violation(code: 1003, "binary messages are not part of the Realtime API")
                activity.violation = violation.description
                activity.closeCode = Int(violation.code)
                state.outbox.put(.control(WebSocket.close(violation.code, violation.description)))
                break reading
            case .ping(let payload):
                state.outbox.put(.control(WebSocket.frame(.pong, payload)))
            case .pong:
                continue
            case .close(let payload):
                // Echoed, as RFC 6455 asks: the client's code is the one the close carries.
                activity.closeCode = payload.count >= 2 ? Int(payload[payload.startIndex]) << 8 | Int(payload[payload.startIndex + 1]) : nil
                state.outbox.put(.control(WebSocket.frame(.close, payload.prefix(2))))
                break reading
            }
        }
        // Items still being heard have no one left to hear them.
        state.abandon()
        outbox.finish()
        let (sent, unsent) = await writer.value
        activity.sent = sent
        return (activity, lost ?? unsent)
    }

    /// The session as the reader holds it between messages.
    private struct State {
        var session: RealtimeSession
        let outbox: Outbox
        let sessionID = "sess_\(ID.fresh())"
        /// The item appends are going to, from the first append after a commit.
        var buffer: Buffer?
        /// The last item committed, which the next one follows.
        var previous: String?
        /// Cancels every item still being heard or answered, for when the socket ends first.
        var inFlight: [@Sendable () -> Void] = []

        mutating func receive(_ text: String, transcriber: any Transcriber, _ activity: inout RealtimeActivity) {
            var clientEvent: String?
            do {
                let object = try ClientEvent.object(text)
                clientEvent = object["event_id"] as? String
                switch try ClientEvent.parse(object, onto: session) {
                case .update(let updated):
                    activity.updates += 1
                    session = updated
                    outbox.emit(.sessionUpdated(id: sessionID, session))
                case .append(let bytes):
                    activity.appends += 1
                    try append(bytes, transcriber: transcriber, &activity)
                case .commit:
                    try commit(&activity)
                }
            } catch {
                outbox.emit(.error(error, clientEvent: clientEvent))
            }
        }

        /// `bytes` into the open item, which the first append after a commit opens.
        private mutating func append(_ bytes: Data, transcriber: any Transcriber, _ activity: inout RealtimeActivity) throws(RealtimeError) {
            if buffer == nil {
                let opened = Buffer(transcriber: transcriber, vocabulary: session.vocabulary, outbox: outbox)
                activity.items += 1
                inFlight.append(opened.transcript.cancel)
                buffer = opened
            }
            try buffer!.append(bytes)
        }

        /// The open item ends and is answered; with none open, the commit is refused.
        private mutating func commit(_ activity: inout RealtimeActivity) throws(RealtimeError) {
            guard let buffer else { throw .bufferEmpty }
            self.buffer = nil
            let heard = try buffer.end()
            activity.audioSeconds += heard
            for event in [ServerEvent.committed(item: buffer.id, previous: previous), .itemAdded(item: buffer.id, previous: previous), .itemDone(item: buffer.id, previous: previous)] {
                outbox.emit(event)
            }
            previous = buffer.id
            let deltas = buffer.deltas
            let transcript = buffer.transcript
            inFlight.append(Task { await deltas.settle(transcript, usage: Usage(heard: heard)) }.cancel)
        }

        func abandon() {
            buffer?.abandon()
            for cancel in inFlight { cancel() }
        }
    }
}

/// One item's audio while it is being appended: 24 kHz PCM16 in, 16 kHz clips out to the
/// `transcribe` that opened with it.
private final class Buffer {
    let id: String
    let deltas: Deltas
    let transcript: Task<Transcript, any Error>
    private let clips: AsyncStream<AudioClip>.Continuation
    private let converter: AudioClip.Converter
    /// A byte of a sample whose other byte the next append carries.
    private var carry = Data()
    private var samples = 0

    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(RealtimeAudio.rate), channels: 1, interleaved: true)!

    init(transcriber: any Transcriber, vocabulary: Vocabulary, outbox: Outbox) {
        // [LAW:no-silent-failure] A fixed pair of formats AVFoundation converts between;
        // a throw here is a programming error, so it traps.
        converter = try! AudioClip.Converter(from: Self.format)
        let (stream, clips) = AsyncStream<AudioClip>.makeStream()
        self.clips = clips
        id = "item_\(ID.fresh())"
        let deltas = Deltas(item: id, outbox: outbox)
        self.deltas = deltas
        transcript = Task { try await transcriber.transcribe(stream, expecting: vocabulary, partial: deltas.heard) }
    }

    func append(_ bytes: Data) throws(RealtimeError) {
        let whole = carry + bytes
        let even = whole.count & ~1
        carry = whole.suffix(whole.count - even)
        try deliver(convert(whole.prefix(even)))
    }

    /// The item's audio ends; returns how many seconds of it there were.
    func end() throws(RealtimeError) -> TimeInterval {
        defer { clips.finish() }
        try deliver(Result { try converter.drain() }.mapError { RealtimeError.engineFailed("the audio could not be resampled: \($0)") }.get())
        return AudioClip.duration(for: samples)
    }

    func abandon() {
        clips.finish()
    }

    private func convert(_ pcm: Data) throws(RealtimeError) -> [Float] {
        let frames = pcm.count / 2
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(max(frames, 1)))!
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.copyBytes(to: UnsafeMutableRawBufferPointer(start: buffer.int16ChannelData![0], count: frames * 2))
        do {
            return try converter.convert(buffer)
        } catch {
            throw .engineFailed("the audio could not be resampled: \(error)")
        }
    }

    private func deliver(_ converted: [Float]) {
        samples += converted.count
        clips.yield(AudioClip(samples: converted))
    }
}

/// One item's text on its way out: confirmed words as deltas while it is heard, then the
/// rest and the transcript once it is.
///
/// [LAW:types-are-the-program] Deltas are only ever the words after the ones already sent,
/// taken from `Partial.confirmed`, which the transcript begins with word for word; so the
/// deltas joined are the transcript, and a delta can never take back a word.
private final class Deltas: Sendable {
    let item: String
    private let outbox: Outbox
    /// How many words have gone out as deltas. Held across the send, so deltas leave in
    /// the order their words were heard.
    private let sent = Mutex(0)

    init(item: String, outbox: Outbox) {
        self.item = item
        self.outbox = outbox
    }

    func heard(_ partial: Partial) {
        send(partial.confirmed.words)
    }

    /// Answers the item once `transcript` has been heard: the words not yet sent, then the
    /// transcript, or the reason there is none.
    func settle(_ transcript: Task<Transcript, any Error>, usage: Usage) async {
        switch await transcript.result {
        case .success(let heard):
            send(heard.words)
            outbox.emit(.completed(item: item, transcript: heard.served, usage: usage))
        case .failure(let refusal as VocabularyError):
            outbox.emit(.failed(item: item, .promptRefused("\(refusal)")))
        case .failure(let error):
            outbox.emit(.failed(item: item, .engineFailed("\(error)")))
        }
    }

    private func send(_ words: [Transcript.Word]) {
        sent.withLock { sent in
            guard words.count > sent else { return }
            outbox.emit(.delta(item: item, Transcript(words: Array(words[sent...])).text))
            sent = words.count
        }
    }
}

/// Where every frame bound for the client is put, in order.
final class Outbox: Sendable {
    private let frames: AsyncStream<Outgoing>.Continuation

    init(_ frames: AsyncStream<Outgoing>.Continuation) {
        self.frames = frames
    }

    func emit(_ event: ServerEvent) {
        put(.event(event))
    }

    func put(_ frame: Outgoing) {
        frames.yield(frame)
    }
}

/// A frame bound for the client.
enum Outgoing: Sendable {
    case event(ServerEvent)
    case control(Data)

    var bytes: Data {
        switch self {
        case .event(let event): WebSocket.frame(.text, event.json)
        case .control(let frame): frame
        }
    }
}

/// Everything known about one Realtime socket once it has ended: the Realtime half of
/// its `ServedRequest`. [LAW:nothing-unseen] Items opened less those completed and failed
/// are the items the socket ended before answering.
public struct RealtimeActivity: Sendable, Codable, Equatable {
    public internal(set) var updates = 0
    public internal(set) var appends = 0
    public internal(set) var items = 0
    /// Seconds of audio in the items committed.
    public internal(set) var audioSeconds: Double = 0
    /// The close code the socket ended with, the client's or the server's.
    public internal(set) var closeCode: Int?
    /// How the client broke the protocol, when it did.
    public internal(set) var violation: String?
    public internal(set) var sent = Sent()

    /// The server events that reached the socket, by kind.
    public struct Sent: Sendable, Codable, Equatable {
        public internal(set) var deltas = 0
        public internal(set) var completed = 0
        public internal(set) var failed = 0
        public internal(set) var errors = 0
        public internal(set) var other = 0

        mutating func count(_ frame: Outgoing) {
            guard case .event(let event) = frame else { return }
            switch event {
            case .delta: deltas += 1
            case .completed: completed += 1
            case .failed: failed += 1
            case .error: errors += 1
            case .sessionCreated, .sessionUpdated, .committed, .itemAdded, .itemDone: other += 1
            }
        }
    }
}

extension Reader {
    /// The client's next message, its fragments gathered by `assembler`.
    mutating func message(_ assembler: inout WebSocket.Assembler, limit: Int) async throws -> WebSocket.Message {
        while true {
            let frame = try await next { bytes throws(WebSocket.Violation) in try WebSocket.parse(bytes, limit: limit) }
            if let message = try assembler.take(frame, limit: limit) { return message }
        }
    }
}
