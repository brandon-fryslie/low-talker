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
    /// The most audio one item may hold, in seconds.
    let audio: TimeInterval
    /// The most items the socket holds at once, being appended or still being heard.
    let items: Int

    /// The most one message may hold. Pipecat's appends are about 5 KB of base64 each.
    static let messageLimit = 1 << 20

    /// Serves the socket until the client closes it, breaks the protocol, or is lost, and
    /// says what happened on it.
    func run(_ connection: NWConnection, _ reader: inout Reader) async -> (RealtimeActivity, lost: String?) {
        let (outgoing, frames) = AsyncStream<Outgoing>.makeStream()
        let outbox = Outbox(frames)
        // [LAW:single-enforcer] The one writer: every frame goes out in the order it was
        // put in the outbox, and is counted once it has gone.
        let writer = Task {
            var sent = RealtimeActivity.Sent()
            for await frame in outgoing {
                do {
                    try await connection.send(frame.bytes)
                } catch {
                    // Nothing more can reach the client, so the reader stops too: the
                    // cancel fails its pending read.
                    connection.cancel()
                    return (sent, "\(error)" as String?)
                }
                sent.count(frame)
            }
            return (sent, nil as String?)
        }
        var activity = RealtimeActivity()
        // [LAW:no-ambient-temporal-coupling] Every item is a child of `items`, so none
        // outlives the socket, and each is gone from it once answered.
        let lost = await withDiscardingTaskGroup { items in
            var state = State(session: RealtimeSession(), outbox: outbox, audio: audio, holding: Holding(limit: self.items))
            state.outbox.emit(.sessionCreated(id: state.sessionID, state.session))
            var assembler = WebSocket.Assembler()
            /// The frame the server ends with; none when the connection was lost.
            var last: Data?
            var lost: String?
            reading: while true {
                let message: WebSocket.Message
                do {
                    message = try await reader.message(&assembler, limit: Self.messageLimit)
                } catch let violation as WebSocket.Violation {
                    activity.violation = violation.description
                    activity.closeCode = Int(violation.code)
                    last = WebSocket.close(violation.code, violation.description)
                    break reading
                } catch {
                    lost = "\(error)"
                    break reading
                }
                switch message {
                case .text(let text):
                    await state.receive(text, transcriber: transcriber, &activity, &items)
                case .binary:
                    let violation = WebSocket.Violation(code: 1003, "binary messages are not part of the Realtime API")
                    activity.violation = violation.description
                    activity.closeCode = Int(violation.code)
                    last = WebSocket.close(violation.code, violation.description)
                    break reading
                case .ping(let payload):
                    state.outbox.put(.control(WebSocket.frame(.pong, payload)))
                case .pong:
                    continue
                case .close(let code):
                    // Echoed, as RFC 6455 asks: the client's code is the one the close carries.
                    activity.closeCode = code.map(Int.init)
                    last = code.map { WebSocket.close($0) } ?? WebSocket.frame(.close, Data())
                    break reading
                }
            }
            // Closed first, so what items say while they stop is dropped rather than sent
            // after the close. Items still being heard have no one left to hear them.
            outbox.close(last)
            state.abandon()
            items.cancelAll()
            return lost
        }
        let (sent, unsent) = await writer.value
        activity.sent = sent
        return (activity, unsent ?? lost)
    }

    /// The session as the reader holds it between messages.
    private struct State {
        var session: RealtimeSession
        let outbox: Outbox
        let audio: TimeInterval
        let holding: Holding
        let sessionID = "sess_\(ID.fresh())"
        /// The item appends are going to, from the first append after a commit.
        var buffer: Buffer?
        /// The last item committed, which the next one follows.
        var previous: String?

        mutating func receive(_ text: String, transcriber: any Transcriber, _ activity: inout RealtimeActivity, _ items: inout DiscardingTaskGroup) async {
            var clientEvent: String?
            do throws(RealtimeError) {
                let object = try ClientEvent.object(text)
                clientEvent = object["event_id"] as? String
                switch try ClientEvent.parse(object, onto: session) {
                case .update(let updated):
                    activity.updates += 1
                    session = updated
                    outbox.emit(.sessionUpdated(id: sessionID, session))
                case .append(let bytes):
                    activity.appends += 1
                    try await append(bytes, transcriber: transcriber, &activity, &items)
                case .commit:
                    try commit(&activity, &items)
                }
            } catch {
                activity.refused(error)
                outbox.emit(.error(error, clientEvent: clientEvent))
            }
        }

        /// `bytes` into the open item, which the first append after a commit opens; refused
        /// whole, before any of it is taken in, when it would take the item past `audio`.
        /// An item opened while the socket holds its limit waits for one to be heard, reading
        /// nothing meanwhile: the client is held back by its own socket, never refused, since
        /// Pipecat takes any error event as fatal.
        private mutating func append(_ bytes: Data, transcriber: any Transcriber, _ activity: inout RealtimeActivity, _ items: inout DiscardingTaskGroup) async throws(RealtimeError) {
            let seconds = RealtimeAudio.duration(bytes: (buffer?.bytes ?? 0) + bytes.count)
            guard seconds <= audio else { throw .audioTooLong(seconds: seconds, limit: audio) }
            if buffer == nil {
                if await holding.take() { activity.waits += 1 }
                let opened = Buffer(transcriber: transcriber, vocabulary: session.vocabulary, outbox: outbox)
                activity.items += 1
                let transcript = opened.transcript
                let holding = holding
                items.addTask {
                    await withTaskCancellationHandler { _ = await transcript.result } onCancel: { transcript.cancel() }
                    holding.giveBack()
                }
                buffer = opened
            }
            buffer!.append(bytes)
        }

        /// The open item ends and is answered; with no audio in one, the commit is refused.
        private mutating func commit(_ activity: inout RealtimeActivity, _ items: inout DiscardingTaskGroup) throws(RealtimeError) {
            guard let buffer, buffer.hasAudio else { throw .bufferEmpty }
            self.buffer = nil
            let heard = buffer.end()
            activity.audioSeconds += heard
            for event in [ServerEvent.committed(item: buffer.id, previous: previous), .itemAdded(item: buffer.id, previous: previous), .itemDone(item: buffer.id, previous: previous)] {
                outbox.emit(event)
            }
            previous = buffer.id
            let deltas = buffer.deltas
            let transcript = buffer.transcript
            items.addTask { await deltas.settle(transcript, usage: Usage(heard: heard)) }
        }

        func abandon() {
            buffer?.abandon()
        }
    }
}

/// The items one socket holds, from an item's first append until it is heard, and the
/// place one more waits for once the socket holds its limit. [LAW:single-enforcer] The one
/// count of them, so the audio a socket holds is bounded however fast its client commits.
private final class Holding: Sendable {
    private let limit: Int
    /// Items held, and the reader parked for a place, of which there is at most one: a
    /// socket has one reader.
    private let state = Mutex<(held: Int, waiting: CheckedContinuation<Bool, Never>?)>((0, nil))

    init(limit: Int) {
        self.limit = limit
    }

    /// A place for one more item, taken at once or, when the socket holds its limit, once
    /// one is heard; true when it had to wait.
    func take() async -> Bool {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                guard state.held == limit else {
                    state.held += 1
                    return continuation.resume(returning: false)
                }
                state.waiting = continuation
            }
        }
    }

    /// An item is heard: its place goes to the reader waiting for one, or is free.
    func giveBack() {
        state.withLock { state in
            guard let waiting = state.waiting else { return state.held -= 1 }
            state.waiting = nil
            waiting.resume(returning: true)
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
    /// Whole samples appended, at 24 kHz.
    private var received = 0
    /// Samples delivered, at 16 kHz.
    private var samples = 0

    /// What appends carry: PCM16 at 24 kHz.
    private let format: AVAudioFormat

    init(transcriber: any Transcriber, vocabulary: Vocabulary, outbox: Outbox) {
        // [LAW:no-silent-failure] A fixed pair of formats AVFoundation converts between;
        // a throw here, or from converting or draining between them, is a programming
        // error, so it traps.
        format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(RealtimeAudio.rate), channels: 1, interleaved: true)!
        converter = try! AudioClip.Converter(from: format)
        let (stream, clips) = AsyncStream<AudioClip>.makeStream()
        self.clips = clips
        id = "item_\(ID.fresh())"
        let deltas = Deltas(item: id, outbox: outbox)
        self.deltas = deltas
        transcript = Task { try await transcriber.transcribe(stream, expecting: vocabulary, partial: deltas.heard) }
    }

    var hasAudio: Bool { received > 0 }

    /// Bytes appended, the odd one waiting for its sample's other half included.
    var bytes: Int { received * 2 + carry.count }

    func append(_ bytes: Data) {
        let whole = carry + bytes
        let even = whole.count & ~1
        carry = whole.suffix(whole.count - even)
        received += even / 2
        deliver(convert(whole.prefix(even)))
    }

    /// The item's audio ends; returns how many seconds of it there were.
    func end() -> TimeInterval {
        defer { clips.finish() }
        deliver(try! converter.drain())
        return AudioClip.duration(for: samples)
    }

    func abandon() {
        clips.finish()
    }

    private func convert(_ pcm: Data) -> [Float] {
        let frames = pcm.count / 2
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1)))!
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.copyBytes(to: UnsafeMutableRawBufferPointer(start: buffer.int16ChannelData![0], count: frames * 2))
        return try! converter.convert(buffer)
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
/// deltas joined are the transcript's words, and a delta can never take back a word. Like
/// OpenAI's, the first delta keeps the leading space the completed transcript trims.
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

/// Where every frame bound for the client is put, in order, until it is closed.
final class Outbox: Sendable {
    /// Held across each put and the close, so no frame can land after the last.
    private let frames: Mutex<AsyncStream<Outgoing>.Continuation>

    init(_ frames: AsyncStream<Outgoing>.Continuation) {
        self.frames = Mutex(frames)
    }

    func emit(_ event: ServerEvent) {
        put(.event(event))
    }

    /// `frame` bound for the client, or dropped once the outbox is closed.
    func put(_ frame: Outgoing) {
        frames.withLock { _ = $0.yield(frame) }
    }

    /// `last` is the final frame sent; nothing put after it is.
    func close(_ last: Data?) {
        frames.withLock { frames in
            if let last { frames.yield(.control(last)) }
            frames.finish()
        }
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
    /// Client events refused, by their error's code.
    public internal(set) var refusals: [String: Int] = [:]
    /// The most audio a refused append would have taken its item to, in seconds.
    public internal(set) var refusedAudioSeconds: Double?
    public internal(set) var items = 0
    /// Items that waited to open until an earlier one was heard.
    public internal(set) var waits = 0
    /// Seconds of audio in the items committed.
    public internal(set) var audioSeconds: Double = 0
    /// The close code the socket ended with, the client's or the server's.
    public internal(set) var closeCode: Int?
    /// How the client broke the protocol, when it did.
    public internal(set) var violation: String?
    public internal(set) var sent = Sent()

    /// [LAW:single-enforcer] The one place a refused client event's facts become the socket's.
    mutating func refused(_ refusal: RealtimeError) {
        refusals[refusal.code, default: 0] += 1
        if case .audioTooLong(let seconds, _) = refusal { refusedAudioSeconds = max(refusedAudioSeconds ?? 0, seconds) }
    }

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
