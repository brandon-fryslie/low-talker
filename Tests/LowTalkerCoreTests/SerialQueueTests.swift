import LowTalkerCore
import Synchronization
import Testing

/// Counts operations in flight and remembers the most it ever saw at once.
private actor Occupancy {
    private(set) var active = 0
    private(set) var peak = 0

    func enter() {
        active += 1
        peak = max(peak, active)
    }

    func leave() {
        active -= 1
    }
}

private struct Boom: Error {}

/// Something a test holds shut, and whatever arrives at it waits until the test opens
/// it, so an operation can be proven unfinished rather than assumed so because little
/// time has passed. [LAW:no-ambient-temporal-coupling]
private final class Gate: Sendable {
    private struct State {
        var open = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func open() {
        let released = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        released.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let through = state.withLock { state in
                if !state.open { state.waiters.append(continuation) }
                return state.open
            }
            if through { continuation.resume() }
        }
    }
}

/// Raised by an operation as the last thing it does, so a drain that came back early is
/// caught by what has not happened yet.
private final class Flag: Sendable {
    private let value = Mutex(false)
    var raised: Bool { value.withLock { $0 } }
    func raise() { value.withLock { $0 = true } }
}

@Suite struct SerialQueueTests {
    /// Many operations submitted at once, each yielding mid-flight so an unserialized
    /// queue would interleave them. A correct queue passes regardless of scheduling;
    /// only a broken one depends on timing to be caught, and with this many
    /// submissions each suspending twice, it is.
    @Test func operationsNeverOverlap() async throws {
        let queue = SerialQueue()
        let occupancy = Occupancy()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    try await queue.run {
                        await occupancy.enter()
                        await Task.yield()
                        await Task.yield()
                        await occupancy.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await occupancy.peak == 1)
        #expect(await occupancy.active == 0)
    }

    @Test func returnsTheOperationsValue() async throws {
        let queue = SerialQueue()
        #expect(try await queue.run { 42 } == 42)
    }

    /// A failure reaches its own caller and nobody else; the queue keeps going.
    @Test func failureStaysWithItsCaller() async throws {
        let queue = SerialQueue()
        await #expect(throws: Boom.self) {
            try await queue.run { throw Boom() }
        }
        #expect(try await queue.run { "still running" } == "still running")
    }

    /// An operation that submits to its own queue would wait on itself forever. It
    /// is refused instead, and the queue is still usable afterwards.
    @Test func submittingToOwnQueueIsRefusedNotHung() async throws {
        let queue = SerialQueue()
        await #expect(throws: SerialQueueError.self) {
            try await queue.run {
                try await queue.run { "never" }
            }
        }
        #expect(try await queue.run { "still running" } == "still running")
    }

    /// Submitting to a different queue from inside an operation is ordinary nesting.
    @Test func submittingToAnotherQueueIsAllowed() async throws {
        let outer = SerialQueue()
        let inner = SerialQueue()
        let value = try await outer.run {
            try await inner.run { "nested" }
        }
        #expect(value == "nested")
    }

    /// Coming back to a queue through another one is the same wait-on-yourself, one
    /// hop removed, and is refused the same way.
    @Test func submittingToAnEnclosingQueueThroughAnotherIsRefused() async throws {
        let outer = SerialQueue()
        let inner = SerialQueue()
        await #expect(throws: SerialQueueError.self) {
            try await outer.run {
                try await inner.run {
                    try await outer.run { "never" }
                }
            }
        }
        #expect(try await outer.run { "still running" } == "still running")
    }

    /// The escape hatch for resubmitting later: a detached task inherits nothing, so
    /// its submission is an ordinary one once the operation that spawned it is done.
    @Test func detachedTaskMayResubmitAfterItsOperationReturns() async throws {
        let queue = SerialQueue()
        let later = try await queue.run {
            Task.detached { try await queue.run { "later" } }
        }
        #expect(try await later.value == "later")
    }

    /// `drain` is what a caller waits on before it shuts down, so what it must not do is
    /// come back while work the queue already accepted is still running. The operation is
    /// held at a gate until the drain is asked for, and yields on its way out afterwards,
    /// so a drain that did not wait is caught by the flag still being down.
    @Test func drainReturnsOnlyAfterWorkAlreadySubmittedHasFinished() async throws {
        let queue = SerialQueue()
        let started = Gate()
        let held = Gate()
        let finished = Flag()
        let submitted = Task {
            try await queue.run {
                started.open()
                await held.wait()
                for _ in 0..<50 { await Task.yield() }
                finished.raise()
            }
        }
        // Running, so the queue has accepted it and a drain owes it a wait.
        await started.wait()
        #expect(!finished.raised)
        held.open()
        await queue.drain()
        #expect(finished.raised)
        try await submitted.value
    }

    /// However it ended: a failed operation is waited for like any other, and its failure
    /// stays with its own caller - draining is not a `try`.
    @Test func drainWaitsForAFailedOperationAndDoesNotCarryItsFailure() async throws {
        let queue = SerialQueue()
        let started = Gate()
        let held = Gate()
        let finished = Flag()
        let submitted = Task {
            try await queue.run {
                started.open()
                await held.wait()
                for _ in 0..<50 { await Task.yield() }
                finished.raise()
                throw Boom()
            }
        }
        await started.wait()
        held.open()
        await queue.drain()
        #expect(finished.raised)
        await #expect(throws: Boom.self) { try await submitted.value }
    }
}
