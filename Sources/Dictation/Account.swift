import Insertion
import LowTalkerCore

/// What a failure tells the log: its facts, in the clear, and the words the person dictated,
/// when it carries any, which the log keeps private. The split the session line makes:
/// numbers public, words private, decided by the type that owns them.
public struct Account: Equatable, Sendable {
    public let facts: String
    public let dictated: String?

    public init(facts: String, dictated: String? = nil) {
        self.facts = facts
        self.dictated = dictated
    }
}

/// A failure the dictation loop can report, which says by its type which part of its account
/// is what the person dictated. The loop's seams throw closed types and it reports only these,
/// so a failure that has not said cannot reach the log, and the log never guesses.
/// [LAW:types-are-the-program]
public protocol Accounted: Error, CustomStringConvertible {
    var account: Account { get }
}

/// A failure whose description is facts about the press - counts, names, durations - and
/// never the words said, so its whole account is in the clear.
public protocol WordFree: Accounted {}

extension WordFree {
    public var account: Account { Account(facts: description) }
}

extension NoMicrophone: WordFree {}
extension SerialQueueError: WordFree {}

// An enum whose cases could one day carry the words names each case, so a case added
// to it does not compile until it has said what it carries.

extension InsertFailure: Accounted {
    public var account: Account {
        switch self {
        case .refused, .notYetTaken, .unreachable, .answererUnreadable: Account(facts: description)
        }
    }
}

extension TranscriptionFailure: Accounted {
    public var account: Account {
        switch self {
        case .cancelled, .nothingSpoken, .vocabulary, .engine: Account(facts: description)
        case .unreadable(let reading): reading.account
        }
    }
}

extension WhisperKitTranscriberError: Accounted {
    public var account: Account {
        switch self {
        case .tokenizerNotLoaded: Account(facts: description)
        case .speechWithoutWords(let text):
            Account(facts: "WhisperKit returned a segment of \(text.count) characters without word timings", dictated: text)
        case .probabilityOutsideUnitInterval(let word):
            Account(facts: "WhisperKit gave a word probability \(word.probability), outside \(Confidence.range)", dictated: word.word)
        case .wordEndsBeforeStart(let word):
            Account(facts: "WhisperKit gave a word an end \(word.end) before its start \(word.start)", dictated: word.word)
        }
    }
}

/// The engine was not there for a press: its model failed to load, or something else holds it.
///
/// Word-free whatever its cause: the engine is asked for before it is handed any of the
/// press's audio, so nothing it says can be a reading of what was dictated.
public struct EngineUnavailable: WordFree {
    public let cause: any Error

    public init(_ cause: any Error) {
        self.cause = cause
    }

    public var description: String { "\(cause)" }
}
