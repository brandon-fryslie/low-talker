import AVFoundation
import Foundation
import LowTalkerCore
import Network
import Synchronization

/// One Realtime transcription socket, from the 101 to the close (epic low-serve-axq): the
/// client's events read in order, each item heard by one streaming `transcribe`, and every
/// server event sent through one outbox.
struct RealtimeSocket {
    /// One of the server's places for sockets, held for as long as this one is.
    let place: Place
    let transcriber: any Transcriber
    /// The most audio the socket holds at once, in seconds, across every item from its
    /// first append until it is heard.
    let audio: TimeInterval

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
            var state = State(session: RealtimeSession(), outbox: outbox, held: HeldAudio(limit: audio))
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
                    state.receive(text, transcriber: transcriber, &activity, &items)
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
        let held: HeldAudio
        let sessionID = "sess_\(ID.fresh())"
        /// The item appends are going to, from the first append after a commit.
        var buffer: Buffer?
        /// The last item committed: the one the next follows, and its answer, which the
        /// next is heard after.
        var last: (id: String, answered: Task<Void, Never>)?

        mutating func receive(_ text: String, transcriber: any Transcriber, _ activity: inout RealtimeActivity, _ items: inout DiscardingTaskGroup) {
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
                    try append(bytes, transcriber: transcriber, &activity, &items)
                case .commit:
                    try commit(&activity, &items)
                }
            } catch {
                activity.refused(error)
                outbox.emit(.error(error, clientEvent: clientEvent))
            }
        }

        /// `bytes` into the open item, which the first append after a commit opens; refused
        /// whole, before any of it is taken in, when it would take the socket's held audio
        /// past its limit. The reader never waits on the engine: a socket whose items are
        /// still being heard goes on reading, pings included, so engine contention delays
        /// its transcripts and nothing else (low-serve-axq.32w).
        private mutating func append(_ bytes: Data, transcriber: any Transcriber, _ activity: inout RealtimeActivity, _ items: inout DiscardingTaskGroup) throws(RealtimeError) {
            let holding = try held.take(bytes: bytes.count, items: buffer == nil ? 1 : 0)
            activity.heldAudioSeconds = max(activity.heldAudioSeconds, holding.seconds)
            activity.heldItems = max(activity.heldItems, holding.items)
            if buffer == nil {
                let opened = Buffer(transcriber: transcriber, vocabulary: session.vocabulary, outbox: outbox, after: last?.answered)
                activity.items += 1
                let transcript = opened.transcript
                items.addTask {
                    await withTaskCancellationHandler { _ = await transcript.result } onCancel: { transcript.cancel() }
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
            for event in [ServerEvent.committed(item: buffer.id, previous: last?.id), .itemAdded(item: buffer.id, previous: last?.id), .itemDone(item: buffer.id, previous: last?.id)] {
                outbox.emit(event)
            }
            let deltas = buffer.deltas
            let transcript = buffer.transcript
            let (held, bytes) = (held, buffer.bytes)
            // [LAW:no-ambient-temporal-coupling] Freed before the item is answered, so a
            // client that appends on hearing it finds the room already there.
            let answered = Task {
                let result = await transcript.result
                held.giveBack(itemOf: bytes)
                deltas.settle(result, usage: Usage(heard: heard))
            }
            last = (buffer.id, answered)
            items.addTask { await answered.value }
        }

        func abandon() {
            buffer?.abandon()
        }
    }
}

/// What one socket holds, from each append until its item is heard: the bytes appends
/// carry, and a second more of them for each item, since holding an item costs more than
/// its audio. [LAW:single-enforcer] The one count of it, so the memory a socket holds is
/// bounded however many items, however short, its client commits while the engine is busy.
private final class HeldAudio: Sendable {
    /// What an item costs beyond its audio, in bytes of audio: a second of it.
    private static let perItem = RealtimeAudio.rate * 2
    private let limit: TimeInterval
    private let held = Mutex((bytes: 0, items: 0))

    init(limit: TimeInterval) {
        self.limit = limit
    }

    /// `bytes` more held in `items` more items, refused whole when they would take the
    /// socket past its limit; returns what the socket holds with them.
    func take(bytes: Int, items: Int) throws(RealtimeError) -> (seconds: TimeInterval, items: Int) {
        try held.withLock { held throws(RealtimeError) in
            let charged = held.bytes + bytes + items * Self.perItem
            let seconds = RealtimeAudio.duration(bytes: charged)
            guard seconds <= limit else { throw .audioTooLong(seconds: seconds, limit: limit) }
            held = (charged, held.items + items)
            return (seconds, held.items)
        }
    }

    /// An item is heard, and what it held, its `bytes` of audio among it, is free.
    func giveBack(itemOf bytes: Int) {
        held.withLock { $0 = ($0.bytes - bytes - Self.perItem, $0.items - 1) }
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

    /// `after` is the item before this one, once it is answered.
    init(transcriber: any Transcriber, vocabulary: Vocabulary, outbox: Outbox, after previous: Task<Void, Never>?) {
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
        // [LAW:no-ambient-temporal-coupling] An item is heard only once the one before it
        // is answered, so a socket's items are answered in the order they were committed:
        // the engine takes decodes in turn, but an item's several passes are not one turn.
        // Its audio waits in `stream` meanwhile, within the socket's held audio.
        transcript = Task {
            await previous?.value
            return try await transcriber.transcribe(stream, expecting: vocabulary, partial: deltas.heard)
        }
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

    /// Answers the item with what it was heard as: the words not yet sent, then the
    /// transcript, or the reason there is none.
    func settle(_ transcript: Result<Transcript, any Error>, usage: Usage) {
        switch transcript {
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
    /// The most audio a refused append would have taken the socket's held audio to, in seconds.
    public internal(set) var refusedAudioSeconds: Double?
    public internal(set) var items = 0
    /// The most the socket held at once, in seconds: the audio of items not yet heard and a
    /// second for each.
    public internal(set) var heldAudioSeconds: Double = 0
    /// The most items the socket held at once, each heard only after the one before it.
    public internal(set) var heldItems = 0
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
