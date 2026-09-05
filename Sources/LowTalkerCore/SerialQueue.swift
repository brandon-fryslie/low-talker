/// Runs operations one at a time: each waits for every earlier submission to finish,
/// succeed or fail, before it starts.
///
/// [LAW:no-ambient-temporal-coupling] Actor isolation alone does not give this: an
/// actor is reentrant at every `await`, so two calls that each await something can
/// interleave. This actor owns the order explicitly as a chain of tasks, and it is
/// the one place that fact lives for anything that wraps a non-reentrant resource.
public actor SerialQueue {
    /// The latest submission, whatever its outcome. The next one awaits it.
    private var tail: Task<Void, Never>?

    /// The queue whose operation the current task is running, if any. An operation
    /// that submits to its own queue would wait on itself forever, so `run` reads
    /// this and refuses instead.
    @TaskLocal private static var running: ObjectIdentifier?

    public init() {}

    public func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let id = ObjectIdentifier(self)
        // [LAW:no-silent-failure] The alternative is a hang with no diagnostics.
        guard Self.running != id else { throw SerialQueueError.reentrantSubmission }
        let earlier = tail
        let task = Task {
            await earlier?.value
            return try await Self.$running.withValue(id) { try await operation() }
        }
        // Only the order matters to the next submission; this one's outcome goes to
        // its own caller below.
        tail = Task { _ = await task.result }
        return try await task.value
    }
}

public enum SerialQueueError: Error, CustomStringConvertible {
    /// An operation submitted to the queue it is running on.
    case reentrantSubmission

    public var description: String {
        switch self {
        case .reentrantSubmission:
            "an operation submitted to its own SerialQueue, which would wait on itself forever"
        }
    }
}
