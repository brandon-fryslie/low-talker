import LowTalkerCore
import Testing
import TestProbes

/// The gate's own contract, proven here because every suite that holds work at one
/// depends on it: a waiter that is cancelled comes back, and a gate nobody opens is
/// still not a place a run can be lost.
///
/// Each waiter raises a flag on its way out and is read through `holds` rather than
/// awaited, because awaiting one is the failure itself: a gate that keeps a cancelled
/// waiter keeps whoever awaits it too, and a suite that hangs is a run with no result
/// rather than a run with a red test. [LAW:no-silent-failure]
@Suite struct GateTests {
    @Test func aWaiterCancelledAtTheGateComesBackAndLeavesNoneWaiting() async throws {
        let gate = Gate()
        let through = Flag()
        let waiting = Task { await gate.wait(); through.raise() }
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { gate.waiting == 1 })
        waiting.cancel()
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { through.raised })
        #expect(gate.waiting == 0)
    }

    /// The other order, arranged rather than raced: the loop leaves only once the
    /// cancellation has landed, so the gate is reached by a task that is already
    /// cancelled and there is nothing filed for the handler to find.
    @Test func aWaiterCancelledBeforeItArrivesIsNotHeldEither() async throws {
        let gate = Gate()
        let through = Flag()
        let waiting = Task {
            while !Task.isCancelled { await Task.yield() }
            await gate.wait()
            through.raise()
        }
        waiting.cancel()
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { through.raised })
        #expect(gate.waiting == 0)
    }

    /// Opening still releases everyone holding, which is what the suites that use a gate
    /// actually ask of it.
    @Test func openingReleasesEveryWaiter() async throws {
        let gate = Gate()
        let both = Flag()
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await gate.wait() }
                group.addTask { await gate.wait() }
            }
            both.raise()
        }
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { gate.waiting == 2 })
        gate.open()
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { both.raised })
        #expect(gate.waiting == 0)
    }
}
