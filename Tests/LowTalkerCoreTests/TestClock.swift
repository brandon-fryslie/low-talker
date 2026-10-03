import Synchronization

/// A clock that stands still until the test moves it. Unlike `StepClock`, a sleep on it
/// suspends until `advance(to:)` reaches its deadline, so whatever the sleeper raced -
/// another task reading the clock - takes its turn at the instant the test holds the
/// hands at, not at whatever instant the machine got round to it.
/// [LAW:no-ambient-temporal-coupling]
final class TestClock: Clock, Sendable {
    typealias Instant = StepClock.Instant

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let wake: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(since: .zero)
        var sleepers: [Sleeper] = []
        var nextID = 0
        /// Tests waiting for something to sleep.
        var watchers: [CheckedContinuation<Instant, Never>] = []
    }

    private let state = Mutex(State())
    let minimumResolution: Duration = .zero

    var now: Instant { state.withLock { $0.now } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (wake: CheckedContinuation<Void, any Error>) in
                let (due, watchers): (Bool, [CheckedContinuation<Instant, Never>]) = state.withLock { state in
                    if Task.isCancelled || deadline <= state.now { return (true, []) }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, wake: wake))
                    defer { state.watchers = [] }
                    return (false, state.watchers)
                }
                if due { wake.resume() }
                watchers.forEach { $0.resume(returning: deadline) }
            }
        } onCancel: {
            let sleeper = state.withLock { state in
                state.sleepers.firstIndex { $0.id == id }.map { state.sleepers.remove(at: $0) }
            }
            sleeper?.wake.resume(throwing: CancellationError())
        }
        try Task.checkCancellation()
    }

    /// The earliest deadline anything is sleeping until, once something sleeps.
    func nextDeadline() async -> Instant {
        await withCheckedContinuation { watcher in
            let earliest = state.withLock { state in
                let earliest = state.sleepers.map(\.deadline).min()
                if earliest == nil { state.watchers.append(watcher) }
                return earliest
            }
            if let earliest { watcher.resume(returning: earliest) }
        }
    }

    /// Moves the hands to `instant` and wakes every sleeper whose deadline it reaches.
    func advance(to instant: Instant) {
        let due = state.withLock { state in
            state.now = instant
            let due = state.sleepers.filter { $0.deadline <= instant }
            state.sleepers.removeAll { $0.deadline <= instant }
            return due
        }
        due.forEach { $0.wake.resume() }
    }
}
