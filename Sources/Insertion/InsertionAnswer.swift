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

/// Why the input method did not insert.
///
/// A closed set rather than a string, so a caller can act on a reason and the compiler
/// says which reasons it has not considered; each one is also what the log line says, so
/// there is one spelling of each fact. [LAW:one-source-of-truth]
public enum Refusal: String, Codable, CaseIterable, Equatable, Sendable, CustomStringConvertible {
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
/// Cut at the one axis any caller acts on, so that the compiler carries the cut rather
/// than a reader remembering it: **a request that was never taken is words that certainly
/// did not land, and an answer that never came back is words that may well have.** Those
/// are opposite facts, fixed differently and read differently, and the consumer that
/// branches on them is low-input-method-s71.b26's executor - it puts the words on the
/// clipboard when the cursor certainly did not get them, and touches nothing when it may
/// have, because words that may have landed must not be delivered a second time. One flat
/// list of five cases would leave that executor free to copy on the wrong one; nesting the
/// five under the two makes copying on a may-have-landed a thing nobody can write.
/// [LAW:types-are-the-program] [LAW:no-silent-failure] Nothing here is retried and nothing
/// is guessed.
public enum Unreachable: Error, Equatable, Sendable, CustomStringConvertible {
    case didNotLand(DidNotLand)
    case mayHaveLanded(MayHaveLanded)

    /// The question never reached the far end at all, so the cursor certainly did not get
    /// the words and whoever asked is free to put them somewhere else.
    public enum DidNotLand: Equatable, Sendable, CustomStringConvertible {
        case nothingIsListening(port: String)
        /// The send itself timed out, which is the message never entering the far end's
        /// queue - not the far end taking it and staying quiet.
        case requestWasNotTaken(port: String, after: Duration)

        public var description: String {
            switch self {
            case let .nothingIsListening(port):
                "no input method is answering on \(port); it is not installed, or not selected"
            case let .requestWasNotTaken(port, after):
                "the input method on \(port) did not take the request within \(after), so the words did not land"
            }
        }
    }

    /// The channel broke where nobody at this end can see which side of the commit it
    /// broke on, so the far end may already have put the words in the document.
    public enum MayHaveLanded: Equatable, Sendable, CustomStringConvertible {
        case answerDidNotArrive(port: String, after: Duration)
        /// A status none of the others names, which is the arm every unknown status takes.
        /// Here, and not beside `nothingIsListening`, because a status this end cannot read
        /// says nothing about which side of the commit the channel broke on, and the only
        /// safe reading of that silence is that the far end may already hold the words. The
        /// cost of reading it that way is an utterance neither inserted nor copied whenever
        /// the status did in fact mean the request never left; the cost of reading it the
        /// other way is the same sentence in the document twice, which is worse.
        ///
        /// The invalid-port status is NOT one of these. It is answered as
        /// `DidNotLand.nothingIsListening`, because a port that went invalid between being
        /// resolved and being sent to never took the request.
        case sendFailed(port: String, status: Int32)
        /// Bytes came back that are not an answer, which is what an input method left
        /// running from before an update says: it inserted the words and described it in
        /// the shape it knew. Here, and not beside `nothingIsListening`, for exactly that
        /// reason - the words are in the document.
        case answerWasNotReadable(port: String, bytes: Int)

        public var description: String {
            switch self {
            case let .answerDidNotArrive(port, after):
                "the input method on \(port) took the request but did not answer within \(after), so the words may have landed"
            case let .sendFailed(port, status):
                "the request to \(port) failed: CFMessagePort status \(status), so the words may have landed"
            case let .answerWasNotReadable(port, bytes):
                "the input method on \(port) answered \(bytes) bytes that are not an answer, so the words may have landed"
            }
        }
    }

    public var description: String {
        switch self {
        case let .didNotLand(why): why.description
        case let .mayHaveLanded(why): why.description
        }
    }
}

/// Why the words did not reach the cursor, for the caller that treats every reason here
/// the same way. The membership rule is the whole of it: every reason here is one where
/// the words certainly did not land, and that is what makes putting them somewhere else
/// safe rather than a second delivery of a sentence already in the document. It is not a
/// rule about what went wrong - an input method that looked and an input method that was
/// never reached are both in here, because the words are equally not in the document.
///
/// `Unreachable.MayHaveLanded` is not among these and cannot be added to them, which is
/// the reason this is a sum of two named halves and not a reason string. Nor is it a
/// widened `Refusal`: a refusal crosses the wire from the far end, and `Refusal` stays
/// exactly the set of things an input method can say about a cursor it looked at.
/// [LAW:types-are-the-program]
public enum NotAtTheCursor: Equatable, Sendable, CustomStringConvertible {
    /// An input method looked at the cursor and said what it would not do with it.
    case refused(Refusal)
    /// The question never got to an input method for one to look at all.
    ///
    /// Not the same as there being none. Nothing may be listening, which is an uninstalled
    /// bundle or an unselected source - or one may be running and simply never have taken
    /// this request, its queue full behind a client that is not draining. The wrapped case
    /// says which, and anything that wants to tell the person to install or select must
    /// read that rather than the presence of this case. [FRAMING:representation]
    case unreachable(Unreachable.DidNotLand)

    public var description: String {
        switch self {
        case let .refused(refusal): refusal.description
        case let .unreachable(why): why.description
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
