import LowTalkerCore
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
}
