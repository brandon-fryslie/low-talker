/// A run that stopped because something else failed under it, carrying that failure.
///
/// Each layer that stops a run wraps what stopped it with what only that layer knows - how
/// many characters landed, which actions were done - so the failure a caller has to act on
/// sits several causes down. [LAW:locality-or-seam] Each wrapper declares this beside its
/// `cause`, in place of `Error`, so a new wrapper is marked where it is written; one left
/// unmarked hides everything under it from `causes`, as `PointingStopped` once did.
public protocol StoppedPartWay: Error {
    var cause: any Error { get }
}

public extension Error {
    /// This error and every cause under it, outermost first.
    var causes: [any Error] {
        Array(sequence(first: self as any Error) { ($0 as? any StoppedPartWay)?.cause })
    }
}
