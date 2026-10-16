extension Result where Success: Sendable {
    /// The outcome of an async body as a value, keeping the type it throws: what an `async
    /// let` or a `Task` holds when its failure must stay typed, since neither throws typed.
    /// The body runs on the caller's actor, as it would have run inline; Swift 6.1 still
    /// sends its result back across that boundary, so the result must be `Sendable`.
    public init(isolation: isolated (any Actor)? = #isolation, catching body: () async throws(Failure) -> Success) async {
        do throws(Failure) {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}
