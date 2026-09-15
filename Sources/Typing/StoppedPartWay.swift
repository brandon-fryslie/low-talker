/// A run that stopped because something else failed under it, carrying that failure.
///
/// Each layer that stops a run wraps what stopped it with what only that layer knows - how
/// many characters landed, which actions were done - so the failure a caller has to act on
/// sits several causes down. [LAW:types-are-the-program] A conformance rather than a list
/// of the wrappers kept at the one place that reads through them, so a wrapper added later
/// is read through by existing rather than skipped by a list nobody updated.
public protocol StoppedPartWay: Error {
    var cause: any Error { get }
}

public extension Error {
    /// This error and every cause under it, outermost first.
    var causes: [any Error] {
        Array(sequence(first: self as any Error) { ($0 as? any StoppedPartWay)?.cause })
    }
}

extension TypingStopped: StoppedPartWay {}
extension ChordStopped: StoppedPartWay {}
extension RouteStopped: StoppedPartWay {}
