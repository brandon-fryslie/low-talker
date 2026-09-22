import Foundation

/// What the input method did with the text it was asked to insert.
///
/// Two outcomes and not a thrown error for the second, because a refusal is an answer the
/// program acts on rather than a failure it recovers from: low-input-method-s71.b26 puts
/// the words on the clipboard when it reads one, which is work, not error handling. What
/// IS thrown is `Unreachable` - the transport failing to carry the question at all, which
/// is a different fact and deserves a different shape. [LAW:types-are-the-program]
public enum InsertionAnswer: Codable, Equatable, Sendable {
    /// Committed into the client in front, replacing nothing.
    case inserted(characters: Int)
    /// Not committed, and why.
    case refused(Refusal)
}

/// Why the input method did not insert.
///
/// A closed set rather than a string, so a caller can act on a reason and the compiler
/// says which reasons it has not considered; each one is also what the log line says, so
/// there is one spelling of each fact. [LAW:one-source-of-truth]
public enum Refusal: String, Codable, Equatable, Sendable, CustomStringConvertible {
    /// Nothing has focus, so there is no client to commit into. The desktop is the plain
    /// case: no text field, nowhere for words to go.
    case noClientHasFocus
    /// There is a cursor, and it belongs to an app the person has since switched away
    /// from. Its own reason and not `noClientHasFocus`, because the two are fixed
    /// differently: this one is words arriving while the person is somewhere else.
    case cursorIsInAnotherApp
    /// The bytes that arrived were not text. Answered rather than dropped, because a
    /// sender that hears nothing waits out its whole timeout and learns nothing.
    /// [LAW:no-silent-failure]
    case requestWasNotText

    public var description: String {
        switch self {
        case .noClientHasFocus: "no client has focus"
        case .cursorIsInAnotherApp: "the cursor is in an app that is not in front"
        case .requestWasNotText: "the request was not text"
        }
    }
}

/// The transport failing to carry the question, which is never an answer.
///
/// Named cases and not a reason string, and in particular **the two timeouts are two
/// cases**: a request that was never taken is words that certainly did not land, and an
/// answer that never came back is words that may well have. Those are opposite facts, and
/// low-input-method-s71.b26 decides whether to put the words on the clipboard by reading
/// them - one case for both would be the conflation this whole module exists to prevent.
/// [LAW:types-are-the-program] [LAW:no-silent-failure] Nothing here is retried and nothing
/// is guessed.
public enum Unreachable: Error, Equatable, CustomStringConvertible {
    case nothingIsListening(port: String)
    case requestWasNotTaken(port: String, after: Duration)
    case answerDidNotArrive(port: String, after: Duration)
    /// A status none of the others names, and not a did-not-land: the invalid-port and
    /// transport errors say the channel broke without saying whether it broke before or
    /// after the far end took the request. So this reads with `answerDidNotArrive` and
    /// never with `requestWasNotTaken`.
    case sendFailed(port: String, status: Int32)
    case answerWasNotReadable(port: String, bytes: Int)

    public var description: String {
        switch self {
        case let .nothingIsListening(port):
            "no input method is answering on \(port); it is not installed, or not selected"
        case let .requestWasNotTaken(port, after):
            "the input method on \(port) did not take the request within \(after), so the words did not land"
        case let .answerDidNotArrive(port, after):
            "the input method on \(port) took the request but did not answer within \(after), so the words may have landed"
        case let .sendFailed(port, status):
            "the request to \(port) failed: CFMessagePort status \(status), so the words may have landed"
        case let .answerWasNotReadable(port, bytes):
            "the input method on \(port) answered \(bytes) bytes that are not an answer"
        }
    }
}

/// The wire, which is the one place either half turns a value into bytes or back.
/// [LAW:single-enforcer]
///
/// The request is the text and nothing else, so it crosses as its own UTF-8 and carries no
/// envelope to keep in step. The answer is a sum type, so it crosses as JSON, which is the
/// codec Swift already writes for one. Both directions are held by tests against the
/// values, never against the bytes: what matters is that what goes in comes out.
/// [LAW:behavior-not-structure]
enum Wire {
    static func request(_ text: String) -> Data { Data(text.utf8) }

    /// [LAW:parse-dont-validate] Hands back the text or nothing at all; a caller cannot
    /// receive bytes it has not established are text.
    static func text(of request: Data) -> String? { String(data: request, encoding: .utf8) }

    static func answer(_ answer: InsertionAnswer) -> Data {
        // The encoder cannot fail on this type: every case holds `Codable` primitives and
        // nothing else. Said here, at the one place it is true, rather than as a throw
        // every caller would carry and none could act on.
        try! JSONEncoder().encode(answer)
    }

    static func answer(of data: Data) -> InsertionAnswer? {
        try? JSONDecoder().decode(InsertionAnswer.self, from: data)
    }
}
