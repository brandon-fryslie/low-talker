import Insertion
import LowTalkerCore

/// A failure a dictation can report, and what of it a public log may carry.
///
/// [LAW:types-are-the-program] The loop reports nothing else, so whether a failure's account
/// can be said out loud is a fact its type declares before it compiles, never a guess made
/// where it is logged. A failure that is facts about the press is `WordFree`; one that can
/// carry the words the person dictated says what is left of it without them.
public protocol SessionFailure: Error, CustomStringConvertible {
    /// The failure as a public log may tell it: `description`, less any words dictated.
    var publicAccount: String { get }
}

/// A failure whose description is facts about the press - counts, names, durations - and
/// never the words said, so a log carries it whole. Declared beside each type that keeps
/// the promise. [LAW:nothing-unseen]
public protocol WordFree: SessionFailure {}

extension WordFree {
    public var publicAccount: String { description }
}

/// Every way an insert fails names a reason, a port or a count of characters, never the text.
extension InsertFailure: WordFree {}
extension NoMicrophone: WordFree {}
/// The queue refuses only a wait from inside itself, and says so in those words.
extension SerialQueueError: WordFree {}
