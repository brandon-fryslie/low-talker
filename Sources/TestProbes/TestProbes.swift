import Synchronization

// What a test plants in concurrent work to know where that work has got to, instead of
// inferring it from how much time has passed. [LAW:no-ambient-temporal-coupling]
//
// Its own target rather than a copy in each suite: SwiftPM test targets cannot import
// one another's sources, so a plain target both depend on is where one of each can live
// for both. [LAW:one-source-of-truth] It is in no product, so it ships nowhere.

/// Something a test holds shut, and everything that arrives at it waits until the test
/// opens it. How many are waiting is readable, so a test can prove work is held here.
public final class Gate: Sendable {
    private struct State {
        var open = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    public init() {}

    public var waiting: Int { state.withLock { $0.waiters.count } }

    public func open() {
        let released = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        released.forEach { $0.resume() }
    }

    public func wait() async {
        await withCheckedContinuation { continuation in
            let through = state.withLock { state in
                if !state.open { state.waiters.append(continuation) }
                return state.open
            }
            if through { continuation.resume() }
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
