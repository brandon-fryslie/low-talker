import Foundation
import Testing
import VirtualKeyboard
@testable import lowtalker_keyboardd

/// The daemon's lifecycle as a policy over what the world answers: reached when it runs,
/// started when it does not, and stopped only when this helper started it and could not
/// use it. Driven with answers of the test's own and no daemon. [LAW:behavior-not-structure]
@Suite struct DaemonProcessTests {
    /// A keyboard the policy hands back as it was given. Held by the test, so identity
    /// compares the object and not whatever is allocated at its address next.
    private final class Device {}

    /// What the world answered, and what was asked of it.
    private final class World {
        var connections: [Result<Device, DaemonError>]
        var bringUp: Result<VirtualKeyboard.Startup, DaemonError>
        var launched = 0
        var terminated: [pid_t] = []
        var limitGiven: Duration?
        var lost: (@Sendable (DaemonError) -> Void)?

        init(connections: [Result<Device, DaemonError>], bringUp: Result<VirtualKeyboard.Startup, DaemonError> = .success(World.up)) {
            self.connections = connections
            self.bringUp = bringUp
        }

        static let up = VirtualKeyboard.Startup(answered: .milliseconds(4), ready: .seconds(1))
        static let pid: pid_t = 7

        /// Answers each connection in turn and the last one thereafter.
        var effects: DaemonProcess.Effects<Device> {
            DaemonProcess.Effects(
                connect: { whenLost in
                    let answer = self.connections.count > 1 ? self.connections.removeFirst() : self.connections[0]
                    let device = try answer.get()
                    self.lost = whenLost
                    return device
                },
                bringUp: { _, limit in
                    self.limitGiven = limit
                    return try self.bringUp.get()
                },
                launch: { self.launched += 1; return World.pid },
                terminate: { self.terminated.append($0) }
            )
        }
    }

    /// What `whenLost` was told, readable from the test.
    private final class Told: @unchecked Sendable {
        private let lock = NSLock()
        private var losses: [(DaemonError, DaemonProcess.Origin)] = []
        @Sendable func record(_ error: DaemonError, _ origin: DaemonProcess.Origin) {
            lock.lock(); losses.append((error, origin)); lock.unlock()
        }
        var heard: [(DaemonError, DaemonProcess.Origin)] {
            lock.lock(); defer { lock.unlock() }
            return losses
        }
    }

    @Test func aDaemonFoundRunningIsUsedAndNeverStarted() throws {
        let device = Device()
        let world = World(connections: [.success(device)])
        let reached = try world.effects.reach(within: .seconds(1)) { _, _ in }
        #expect(reached.keyboard === device)
        #expect(reached.daemon == .alreadyRunning)
        #expect(reached.startup == World.up)
        #expect(world.launched == 0)
        #expect(world.terminated.isEmpty)
    }

    /// Nothing answers, so the daemon is started and reached once it comes up; the loss
    /// handler is told the daemon is this helper's, so it may stop it.
    @Test func aDaemonThatDoesNotAnswerIsStartedAndReachedWhenItComesUp() throws {
        let device = Device()
        let world = World(connections: [.failure(.noSocket(path: "nowhere")), .failure(.socket("connect", ECONNREFUSED)), .success(device)])
        let told = Told()
        let reached = try world.effects.reach(within: .seconds(1), whenLost: told.record)
        #expect(reached.keyboard === device)
        #expect(reached.daemon == .startedHere(World.pid))
        #expect(world.launched == 1)
        #expect(world.terminated.isEmpty)
        let whenLost = try #require(world.lost)
        whenLost(.closed)
        #expect(told.heard.count == 1)
        #expect(told.heard.first?.0 == .closed)
        #expect(told.heard.first?.1 == .startedHere(World.pid))
    }

    /// Connecting and bringing up wait on different things, so the keyboard is given the
    /// whole limit however long the connection took of it.
    @Test func bringingUpIsGivenTheWholeLimit() throws {
        let world = World(connections: [.failure(.noSocket(path: "nowhere")), .success(Device())])
        _ = try world.effects.reach(within: .milliseconds(300)) { _, _ in }
        #expect(world.limitGiven == .milliseconds(300))
    }

    /// A daemon started here that never answers is stopped before the failure leaves, and
    /// the failure is the daemon's last refusal.
    @Test func aStartedDaemonThatNeverAnswersIsStoppedAndTheRefusalThrown() throws {
        let world = World(connections: [.failure(.noSocket(path: "nowhere"))])
        #expect(throws: DaemonError.noSocket(path: "nowhere")) { try world.effects.reach(within: .milliseconds(150)) { _, _ in } }
        #expect(world.launched == 1)
        #expect(world.terminated == [World.pid])
    }

    @Test func aKeyboardThatWillNotComeUpStopsTheDaemonThisStarted() throws {
        let world = World(connections: [.failure(.noSocket(path: "nowhere")), .success(Device())], bringUp: .failure(.silent))
        #expect(throws: DaemonError.silent) { try world.effects.reach(within: .seconds(1)) { _, _ in } }
        #expect(world.terminated == [World.pid])
    }

    @Test func aKeyboardThatWillNotComeUpLeavesADaemonSomebodyElseRuns() throws {
        let world = World(connections: [.success(Device())], bringUp: .failure(.silent))
        #expect(throws: DaemonError.silent) { try world.effects.reach(within: .seconds(1)) { _, _ in } }
        #expect(world.launched == 0)
        #expect(world.terminated.isEmpty)
    }

    @Test func stoppingEndsOnlyTheDaemonThisStarted() {
        let world = World(connections: [])
        world.effects.stop(.alreadyRunning)
        #expect(world.terminated.isEmpty)
        world.effects.stop(.startedHere(World.pid))
        #expect(world.terminated == [World.pid])
    }
}
