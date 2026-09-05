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

    public init() {}

    public func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let earlier = tail
        let task = Task {
            await earlier?.value
            return try await operation()
        }
        // Only the order matters to the next submission; this one's outcome goes to
        // its own caller below.
        tail = Task { _ = await task.result }
        return try await task.value
    }
}
