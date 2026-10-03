import Darwin
import Foundation

/// Which cursor an insert's words may go to.
///
/// [LAW:types-are-the-program] A dictation's words belong together: its first go to the
/// cursor in front, wherever that is, and every later one only to the app those went to.
/// Which of the two an insert is crosses the wire as this value, so the input method, the
/// one process that knows which app holds the cursor, is the one that refuses the rest once
/// the person has moved. [LAW:single-enforcer]
public enum Destination: Codable, Equatable, Sendable, CustomStringConvertible {
    case cursorInFront
    case app(String)

    /// Whether words bound here may go to a cursor in `application`.
    public func admits(_ application: String) -> Bool {
        switch self {
        case .cursorInFront: true
        case .app(let bound): bound == application
        }
    }

    public var description: String {
        switch self {
        case .cursorInFront: "the cursor in front"
        case .app(let bound): "the cursor in front only in \(bound)"
        }
    }
}

/// An insert as the input method is asked it: the words, and where they may go.
public struct InsertRequest: Codable, Equatable, Sendable {
    public let text: String
    public let destination: Destination

    public init(_ text: String, into destination: Destination) {
        self.text = text
        self.destination = destination
    }
}

/// What the input method did with the text it was asked to insert.
///
/// The shape the answer crosses the wire in, which is the only reason it is a sum: the far
/// end has to be able to say any of these. Past `InputMethodInserter` a refusal or words
/// not yet taken is thrown like any other failure, because to the caller it is one - the
/// words are not at the cursor now, and nothing here puts them anywhere else.
/// [LAW:types-are-the-program]
public enum InsertionAnswer: Codable, Equatable, Sendable {
    /// Committed into the client in front, replacing nothing.
    ///
    /// `into` is the app whose client took it, which only this end knows: the app asked
    /// seconds earlier, while the person was still speaking, and by the time the words are
    /// ready the person may be somewhere else. An answer that left it out would leave the
    /// caller to name the app from what it remembered, and a log line naming the wrong
    /// window is worse than one naming none. [FRAMING:representation]
    case inserted(characters: Int, into: String)
    /// Not committed, and why.
    case refused(Refusal)
    /// Handed to the client in front, which did not take them within the input method's
    /// bound. Neither of the others: the words are on their way and land if the app
    /// recovers, so this is never a refusal and must never be retried.
    case notYetTaken(characters: Int, into: String)
}

/// Words handed to an app that did not take them in time: they land if it recovers.
/// Thrown past `InputMethodInserter` like a refusal, because the words are not at the
/// cursor now, and apart from one, because they may yet be. [LAW:types-are-the-program]
public struct NotYetTaken: Error, Equatable, Sendable, CustomStringConvertible {
    public let characters: Int
    public let into: String

    public init(characters: Int, into: String) {
        self.characters = characters
        self.into = into
    }

    public var description: String {
        "WARNING: \(into) did not take the \(characters) characters in time. They land if it recovers; do not dictate them again."
    }
}

/// Words committed at the cursor: how many, and the app whose client took them.
public struct Inserted: Equatable, Sendable {
    public let characters: Int
    public let into: String

    public init(characters: Int, into: String) {
        self.characters = characters
        self.into = into
    }
}

/// Why the input method did not insert.
///
/// A closed set rather than a string, so a caller can act on a reason and the compiler
/// says which reasons it has not considered; each one is also what the log line says, so
/// there is one spelling of each fact. [LAW:one-source-of-truth]
public enum Refusal: String, Error, Codable, CaseIterable, Equatable, Sendable, CustomStringConvertible {
    /// Nothing has focus, so there is no client to commit into. The desktop is the plain
    /// case: no text field, nowhere for words to go.
    case noClientHasFocus
    /// There is a cursor, and it belongs to an app the person has since switched away
    /// from. Its own reason and not `noClientHasFocus`, because the two are fixed
    /// differently: this one is words arriving while the person is somewhere else.
    case cursorIsInAnotherApp
    /// The cursor in front is in another app than the one the dictation's words already
    /// went to. Its own reason and not `cursorIsInAnotherApp`, because nothing is stale
    /// here: the person moved, and the rest of what they said belongs beside the words that
    /// landed, not in whatever they moved to.
    case dictationIsInAnotherApp
    /// The bytes that arrived were not a request. Answered rather than dropped, because a
    /// sender that hears nothing waits out its whole timeout and learns nothing.
    /// [LAW:no-silent-failure]
    case requestWasNotReadable
    /// Some app holds Secure Event Input - Secure Keyboard Entry in Terminal or iTerm2, or a
    /// password field - and while it does, macOS switches every input method off. Its own
    /// reason and not `noClientHasFocus`, because it is fixed somewhere else entirely: not
    /// by clicking into a text field, which is what that one asks for, but in the app that
    /// holds it. Measured on 2026-09-22: iTerm2 with Secure Keyboard Entry on greys this
    /// input method out of the Input menu and it is never handed a client.
    case secureInputIsOn
    /// The request came from a process that is not this installation's app, signed as the
    /// input method is. Answered rather than ignored, so the sender learns why instead of
    /// waiting out its timeout. This installation's own app never reads it: an input method
    /// signed by another certificate than the app fails the app's own check of who answered
    /// first, and that is the error it reports. [LAW:no-silent-failure]
    case senderIsNotThisInstallationsApp
    /// The input method's main thread did not say which cursor is in front in time, so
    /// nothing was committed. It is where IMK makes its own calls into apps, and a hung
    /// app holds it there for up to 3 s at a time (measured on low-input-method-s71.c7d).
    case inputMethodIsBusy

    public var description: String {
        switch self {
        case .noClientHasFocus: "WARNING: No text field has focus. Your dictation was not inserted."
        case .cursorIsInAnotherApp: "WARNING: The cursor is in an app that is not in front. Your dictation was not inserted."
        case .dictationIsInAnotherApp: "WARNING: You moved to another app while dictating. The rest of your dictation was not inserted."
        case .requestWasNotReadable: "WARNING: The input method was asked something it could not read. Nothing was inserted."
        case .secureInputIsOn: "WARNING: An app has secure keyboard entry on, and macOS turns input methods off while it does. Your dictation was not inserted."
        case .senderIsNotThisInstallationsApp:
            "WARNING: The input method takes words only from the app, signed by the certificate that signed it, and this process is not that app. Your dictation was not inserted."
        case .inputMethodIsBusy:
            "WARNING: An app is not answering, and it held the input method up past its time limit. Your dictation was not inserted."
        }
    }
}

/// Where the words were when the channel failed, which is what decides whether saying them
/// again could put them at the cursor twice.
///
/// A property of the moment, not of the failure: the same fault before the words were sent
/// and after is one case holding each of these, never two spellings of it.
/// [LAW:one-source-of-truth]
public enum Words: Equatable, Sendable, CustomStringConvertible {
    /// The channel failed before the words were sent.
    case notSent
    /// The words went out, and nothing came back to say what became of them.
    case mayHaveLanded

    public var description: String {
        switch self {
        case .notSent: "Your dictation was not sent."
        case .mayHaveLanded: "Your dictation may have been inserted."
        }
    }
}

/// The transport failing to carry the question, which is never an answer. [LAW:no-silent-failure]
/// Nothing here is retried and nothing is guessed: each case says what the channel did.
public enum Unreachable: Error, Equatable, Sendable, CustomStringConvertible {
    case nothingIsListening(port: String)
    /// The send itself timed out: the request never entered the far end's queue.
    case requestWasNotTaken(port: String, after: Duration)
    case answerDidNotArrive(port: String, after: Duration)
    /// The far end took the greeting and did not answer it in time, so the words were never
    /// sent.
    case didNotSayWhoItIs(port: String, after: Duration)
    /// The far end took the request and let go of the way back without answering.
    case answerWasAbandoned(port: String)
    /// Whatever answered is not this installation's input method. Found out from its answer
    /// to the greeting, before the words go; after them it is the input method gone before
    /// the kernel could say who had answered.
    case answeredByAStranger(port: String, pid: pid_t, because: PeerIdentity.NotAdmitted, required: PeerIdentity, words: Words)
    /// A Mach status none of the others names, which is the arm every unknown status takes.
    case failed(port: String, status: kern_return_t, words: Words)
    /// Bytes came back that are not an answer, which is what an input method left running
    /// from before an update says: it described what it did in a shape this end no longer
    /// reads.
    case answerWasNotReadable(port: String, bytes: Int, words: Words)

    public var description: String {
        switch self {
        case let .nothingIsListening(port):
            "WARNING: No input method is answering on \(port); it is not installed or not selected. Your dictation was not inserted."
        case let .requestWasNotTaken(port, after):
            "WARNING: The input method on \(port) did not take the request within \(after). Your dictation was not inserted."
        case let .answerDidNotArrive(port, after):
            "WARNING: The input method on \(port) took the request but did not answer within \(after). Your dictation may have been inserted; do not dictate it again."
        case let .didNotSayWhoItIs(port, after):
            "WARNING: The input method on \(port) did not say who it is within \(after). Your dictation was not sent."
        case let .answerWasAbandoned(port):
            "WARNING: The input method on \(port) took the request and went away without answering. Your dictation may have been inserted; do not dictate it again."
        case let .answeredByAStranger(port, pid, because, required, words):
            "WARNING: pid \(pid) answered on \(port) and is not the input method, \(required) - \(because). \(words)"
        case let .failed(port, status, words):
            "WARNING: The request to \(port) failed: \(Mach.describe(status)). \(words)"
        case let .answerWasNotReadable(port, bytes, words):
            "WARNING: The input method on \(port) answered \(bytes) bytes that are not an answer. \(words)"
        }
    }
}

/// The wire, which is the one place either half turns a value into bytes or back.
///
/// Three messages cross it, told apart by their Mach id: the greeting, empty, which the input
/// method answers empty once it has admitted the sender; the words; and, the other way, the
/// modifier keys the input method was just handed, which nobody answers.
/// [LAW:single-enforcer]
///
/// The request and the answer are both values with more than one field, so both cross as
/// JSON, which is the codec Swift already writes for them. Both directions are held by
/// tests against the values, never against the bytes: what matters is that what goes in
/// comes out. [LAW:behavior-not-structure]
enum Wire {
    static let greeting: mach_msg_id_t = 1
    static let insert: mach_msg_id_t = 2
    static let modifiers: mach_msg_id_t = 3

    // The encoder cannot fail on these types: every case holds `Codable` primitives and
    // nothing else. Said here, at the one place it is true, rather than as a throw every
    // caller would carry and none could act on.
    static func request(_ request: InsertRequest) -> Data { try! JSONEncoder().encode(request) }

    /// [LAW:parse-dont-validate] A request or nothing at all.
    static func request(of data: Data) -> InsertRequest? {
        try? JSONDecoder().decode(InsertRequest.self, from: data)
    }

    static func answer(_ answer: InsertionAnswer) -> Data { try! JSONEncoder().encode(answer) }

    /// [LAW:parse-dont-validate] An answer or nothing at all.
    ///
    /// An insert naming no app is not refused here: only this installation's input method
    /// is believed, and it refuses one at its own border, in `Client.init?`. [LAW:single-enforcer]
    static func answer(of data: Data) -> InsertionAnswer? {
        try? JSONDecoder().decode(InsertionAnswer.self, from: data)
    }

    /// Two words, the flags and then the moment, in this Mac's own byte order: both ends run
    /// on the one machine.
    static func modifiers(_ held: HeldModifiers) -> Data {
        withUnsafeBytes(of: (held.flags, held.uptimeNanoseconds)) { Data($0) }
    }

    /// [LAW:parse-dont-validate] Held modifiers or nothing at all: bytes of any other length
    /// are not a message this wire sends.
    static func heldModifiers(of data: Data) -> HeldModifiers? {
        guard data.count == MemoryLayout<(UInt64, UInt64)>.size else { return nil }
        let (flags, uptime) = data.withUnsafeBytes { $0.loadUnaligned(as: (UInt64, UInt64).self) }
        return HeldModifiers(flags: flags, uptimeNanoseconds: uptime)
    }
}
