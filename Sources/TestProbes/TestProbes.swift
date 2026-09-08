import Synchronization

// What a test plants in concurrent work to know where that work has got to, instead of
// inferring it from how much time has passed. [LAW:no-ambient-temporal-coupling]
//
// Its own target rather than a copy in each suite: SwiftPM test targets cannot import
// one another's sources, so a plain target both depend on is where one of each can live
// for both. [LAW:one-source-of-truth] It is in no product, so it ships nowhere.

/// Something a test holds shut, and everything that arrives at it waits until the test
/// opens it. How many are waiting is readable, so a test can prove work is held here.
///
/// A cancelled waiter comes back rather than staying held: a gate that outlived its
/// cancellation would hold a whole suite forever, and a task group whose first failure
/// cancels its siblings is the ordinary way a suite arrives here. Coming back is all it
/// does - the caller reads cancellation where it already reads it, so `wait` stays a
/// thing that returns. [LAW:no-ambient-temporal-coupling]
public final class Gate: Sendable {
    private struct State {
        var open = false
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        var arrivals = 0
    }

    private let state = Mutex(State())

    public init() {}

    public var waiting: Int { state.withLock { $0.waiters.count } }

    public func open() {
        let released = state.withLock { state in
            state.open = true
            defer { state.waiters = [:] }
            return state.waiters
        }
        released.values.forEach { $0.resume() }
    }

    public func wait() async {
        let arrival = state.withLock { state in
            state.arrivals += 1
            return state.arrivals
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancellation is read under the same lock the handler takes, which is
                // what makes the two arrivals meet: whichever gets the lock second finds
                // what the first left, so the continuation is resumed exactly once
                // whether the cancellation lands before this waiter is filed or after.
                let through = state.withLock { state in
                    guard !state.open, !Task.isCancelled else { return true }
                    state.waiters[arrival] = continuation
                    return false
                }
                if through { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: arrival) }?.resume()
        }
    }
}

/// Raised by work as the last thing it does, so a wait that came back early is caught by
/// what has not happened yet rather than by a deadline.
public final class Flag: Sendable {
    private let value = Mutex(false)

    public init() {}

    public var raised: Bool { value.withLock { $0 } }

    public func raise() { value.withLock { $0 = true } }
}
