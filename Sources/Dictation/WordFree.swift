import Insertion
import LowTalkerCore

/// A failure whose description is facts about the press - counts, names, durations - and
/// never the words said, so a log may carry it in the clear. Declared beside each type that
/// keeps the promise; a failure that does not is withheld from the log and says so there.
/// [LAW:no-silent-failure]
public protocol WordFree: Error, CustomStringConvertible {}

extension NoMicrophone: WordFree {}
extension Refusal: WordFree {}
extension Unreachable: WordFree {}
extension NotYetTaken: WordFree {}
