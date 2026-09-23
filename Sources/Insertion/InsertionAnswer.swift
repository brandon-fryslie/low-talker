import Foundation

/// What the input method did with the text it was asked to insert.
///
/// The shape the answer crosses the wire in, which is the only reason it is a sum: the far
/// end has to be able to say either. Past `InputMethodInserter` a refusal is thrown like
/// any other failure, because to the caller it is one - the words are not at the cursor,
/// and nothing here puts them anywhere else. [LAW:types-are-the-program]
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
    /// The bytes that arrived were not text. Answered rather than dropped, because a
    /// sender that hears nothing waits out its whole timeout and learns nothing.
    /// [LAW:no-silent-failure]
    case requestWasNotText
    /// Some app holds Secure Event Input - Secure Keyboard Entry in Terminal or iTerm2, or a
    /// password field - and while it does, macOS switches every input method off. Its own
    /// reason and not `noClientHasFocus`, because it is fixed somewhere else entirely: not
    /// by clicking into a text field, which is what that one asks for, but in the app that
    /// holds it. Measured on 2026-09-22: iTerm2 with Secure Keyboard Entry on greys this
    /// input method out of the Input menu and it is never handed a client.
    case secureInputIsOn

    public var description: String {
        switch self {
        case .noClientHasFocus: "no client has focus"
        case .cursorIsInAnotherApp: "the cursor is in an app that is not in front"
        case .requestWasNotText: "the request was not text"
        case .secureInputIsOn: "an app has secure keyboard entry on, and macOS switches input methods off while it does"
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
    /// A status none of the others names, which is the arm every unknown status takes.
    case sendFailed(port: String, status: Int32)
    /// Bytes came back that are not an answer, which is what an input method left running
    /// from before an update says: it described what it did in a shape this end no longer
    /// reads.
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
            "the input method on \(port) answered \(bytes) bytes that are not an answer, so the words may have landed"
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

    /// [LAW:parse-dont-validate] An answer or nothing at all - and an answer naming its app
    /// with an empty string is nothing at all, because a caller renders that as a line
    /// ending in nothing, which is worse than a line naming no app.
    ///
    /// The far half refuses the same thing at its own border, in `Client.init?`, so our own
    /// input method cannot send one. This is the near half, where what answers is whatever
    /// holds a port name anyone can derive from the public bundle id. Two checks of one
    /// rule, standing at two borders in two processes, and neither is the other's duplicate.
    /// A far end that answers a plausible but wrong app name is not caught here and cannot
    /// be: that needs a sender this end can identify, which is low-input-method-s71.6tk.
    static func answer(of data: Data) -> InsertionAnswer? {
        guard let answer = try? JSONDecoder().decode(InsertionAnswer.self, from: data) else { return nil }
        if case .inserted(_, let into) = answer, into.isEmpty { return nil }
        return answer
    }
}
