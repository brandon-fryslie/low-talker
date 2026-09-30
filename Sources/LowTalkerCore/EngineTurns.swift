import Synchronization

/// The one owner of whose decode the engine runs next. Dictation comes first: a hold takes
/// the engine the moment it begins, cancelling any served decode in flight, and served
/// decodes wait until every hold has had its final transcript. A cancelled decode runs
/// again, whole, once they have, so a served caller sees only the wait and never an error
/// dictation caused.
///
/// [LAW:single-enforcer] The rule lives here and nowhere else. Dictation takes holds and
/// both it and the server decode through this, as `Caller.dictation` and `Caller.served`;
/// neither asks whether the other is busy.
///
/// [LAW:no-ambient-temporal-coupling] Decodes run one at a time, because the engine they
/// share must not be re-entered, and a decode cancelled for a hold is waited out before the
/// hold's first decode starts. State sits under a lock rather than in an actor so that
/// `hold` returns having already cancelled: key-down cannot fall between asking for the
/// engine and a served decode learning it has lost it.
public final class EngineTurns: Sendable {
    /// Who a decode is for.
    public enum Caller: Sendable {
        /// The speaker's own hold: never waits on a served decode and is never cancelled
        /// for one.
        case dictation
        /// Another program asking through the server: waits while any hold is open.
        case served
    }

    /// The owner at one moment, and what it has done so far.
    public struct Reading: Equatable, Sendable {
        public var holds = 0
        /// Whose decode the engine is running, if any.
        public var decoding: Caller?
        /// Decodes waiting their turn.
        public var waiting = 0
        /// Served decodes cancelled because a hold began, each run again afterwards.
        public var cancelled = 0
        /// Served decodes that asked while a hold was open and waited for it.
        public var deferred = 0
    }

    private struct Waiter {
        let id: Int
        let caller: Caller
        let go: CheckedContinuation<Void, any Error>
    }

    private struct Decoding {
        let id: Int
        let caller: Caller
        /// Set once the decode's task exists; a hold that comes before then marks it
        /// preempted and the decode cancels itself as it starts.
        var cancel: (@Sendable () -> Void)?
        var preempted = false
    }

    private struct State {
        var reading = Reading()
        var decoding: Decoding?
        var waiting: [Waiter] = []
        var ids = 0

        /// The next waiter to decode, taken off the queue and made the one decoding, when
        /// the engine is free: the first dictation decode, or else the first served one if
        /// no hold is open.
        mutating func admit() -> CheckedContinuation<Void, any Error>? {
            guard decoding == nil,
                  let next = waiting.firstIndex(where: { $0.caller == .dictation })
                    ?? (reading.holds == 0 ? waiting.indices.first : nil)
            else { return nil }
            let waiter = waiting.remove(at: next)
            decoding = Decoding(id: waiter.id, caller: waiter.caller)
            sync()
            return waiter.go
        }

        mutating func sync() {
            reading.decoding = decoding?.caller
            reading.waiting = waiting.count
        }
    }

    private let state = Mutex(State())

    public init() {}

    public var reading: Reading {
        state.withLock { $0.reading }
    }

    /// Takes the engine for a hold, from key-down until the hold's final transcript is out.
    /// A served decode in flight is cancelled before this returns.
    public func hold() -> EngineHold {
        let (cancel, cancelled) = state.withLock { state -> ((@Sendable () -> Void)?, Bool) in
            state.reading.holds += 1
            guard var decoding = state.decoding, decoding.caller == .served, !decoding.preempted else { return (nil, false) }
            decoding.preempted = true
            state.decoding = decoding
            state.reading.cancelled += 1
            return (decoding.cancel, true)
        }
        cancel?()
        return EngineHold(turns: self, cancelled: cancelled)
    }

    /// Closes one hold and hands the engine on; returns how many served decodes were waiting.
    fileprivate func release() -> Int {
        let (next, waiting) = state.withLock { state in
            state.reading.holds -= 1
            let waiting = state.waiting.count { $0.caller == .served }
            return (state.admit(), waiting)
        }
        next?.resume()
        return waiting
    }

    /// Runs `decode` on the engine when `caller`'s turn comes, and again from the start if a
    /// hold cancelled it; its outcome is the last run's. Cancelling the caller cancels the
    /// decode, whether it is waiting or running.
    public func decode<T: Sendable>(as caller: Caller, _ decode: @escaping @Sendable () async throws -> T) async throws -> T {
        var rerun = false
        while true {
            let id = try await turn(caller, rerun: rerun)
            // A task of its own, so that a hold can cancel the decode without cancelling the
            // caller, who is still owed its outcome.
            let task = Task { try await decode() }
            let preemptedBeforeStart = state.withLock { state in
                state.decoding?.cancel = { task.cancel() }
                return state.decoding?.preempted == true
            }
            if preemptedBeforeStart { task.cancel() }
            let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
            let (preempted, next) = state.withLock { state in
                precondition(state.decoding?.id == id, "the engine ran a decode that was not the one admitted")
                let preempted = state.decoding?.preempted == true
                state.decoding = nil
                state.sync()
                return (preempted, state.admit())
            }
            next?.resume()
            // A decode a hold cancelled failed because of the hold, so it is owed another run;
            // one that finished anyway keeps its result.
            guard preempted, !Task.isCancelled, case .failure = result else { return try result.get() }
            rerun = true
        }
    }

    /// Waits until the engine is `caller`'s. A decode run again after a hold goes first among
    /// served decodes, since it has already had its turn once.
    private func turn(_ caller: Caller, rerun: Bool) async throws -> Int {
        let id = state.withLock { state in
            state.ids += 1
            return state.ids
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (go: CheckedContinuation<Void, any Error>) in
                let (admitted, refused) = state.withLock { state -> (CheckedContinuation<Void, any Error>?, Bool) in
                    // Under the lock the cancellation handler also takes, so a cancel either
                    // lands before this and is seen here, or after and finds the waiter.
                    guard !Task.isCancelled else { return (nil, true) }
                    let waiter = Waiter(id: id, caller: caller, go: go)
                    if rerun { state.waiting.insert(waiter, at: 0) } else { state.waiting.append(waiter) }
                    if caller == .served, !rerun, state.reading.holds > 0 { state.reading.deferred += 1 }
                    state.sync()
                    return (state.admit(), false)
                }
                if refused { go.resume(throwing: CancellationError()) }
                admitted?.resume()
            }
        } onCancel: {
            state.withLock { state -> CheckedContinuation<Void, any Error>? in
                guard let index = state.waiting.firstIndex(where: { $0.id == id }) else { return nil }
                defer { state.sync() }
                return state.waiting.remove(at: index).go
            }?.resume(throwing: CancellationError())
        }
        return id
    }
}

/// The engine taken for one hold. Released once, when the hold's final transcript is out,
/// which is when served decodes may run again.
public final class EngineHold: Sendable {
    /// What a hold put off: whether it cancelled a served decode as it began, and how many
    /// served decodes were waiting on it when it let go.
    public struct Displaced: Equatable, Sendable, CustomStringConvertible {
        public let cancelled: Bool
        public let waiting: Int

        public var description: String {
            "\(cancelled ? 1 : 0) served cancelled, \(waiting) served waiting"
        }
    }

    private let turns: EngineTurns
    private let cancelled: Bool
    private let released = Atomic(false)

    fileprivate init(turns: EngineTurns, cancelled: Bool) {
        self.turns = turns
        self.cancelled = cancelled
    }

    /// Lets the engine go. [LAW:no-silent-failure] A second release would count another
    /// hold's opening as closed, so it is refused.
    @discardableResult
    public func release() -> Displaced {
        precondition(!released.exchange(true, ordering: .relaxed), "a hold was released twice")
        return Displaced(cancelled: cancelled, waiting: turns.release())
    }
}
