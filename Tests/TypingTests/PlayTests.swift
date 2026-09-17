import LowTalkerCore
import Pointing
import Synchronization
import Testing
@testable import Typing

/// A script parsed whole or refused whole, with the line that refused it named.
@Suite struct PlayTests {
    @Test func aScriptIsAStartAndItsReportsInOrder() throws {
        let play = try Play.parse("""
            {"to":{"x":800,"y":500.5}}
            {"t_ms":0,"down":"left"}

            {"t_ms":8.333,"move":{"dx":4,"dy":-127}}
            {"t_ms":8.333,"wheel":{"v":-1,"h":2}}
            {"t_ms":1000,"up":true}
            """)
        #expect(play.start == ScreenPoint(x: 800, y: 500.5))
        #expect(play.events == [
            Play.Timed(at: .zero, report: .down(.left)),
            Play.Timed(at: .nanoseconds(8_333_000), report: .move(Move(x: Count(clamping: 4), y: Count(clamping: -127)))),
            Play.Timed(at: .nanoseconds(8_333_000), report: .wheel(Scroll(vertical: Count(clamping: -1), horizontal: Count(clamping: 2)))),
            Play.Timed(at: .seconds(1), report: .up),
        ])
    }

    /// A script written with Windows line endings is the same script.
    @Test func crlfLinesAreLines() throws {
        let play = try Play.parse(#"{"to":{"x":1,"y":1}}"# + "\r\n" + #"{"t_ms":0,"up":true}"# + "\r\n")
        #expect(play.events == [Play.Timed(at: .zero, report: .up)])
    }

    static let start = #"{"to":{"x":1,"y":1}}"#

    /// Each refusal names the line, and says enough to fix it.
    @Test(arguments: [
        ("", 1, "at least one report"),
        (start, 1, "at least one report"),
        (#"{"t_ms":0,"up":true}"# + "\n" + #"{"t_ms":0,"up":true}"#, 1, "\"t_ms\""),
        (start + "\n" + #"{"t_ms":0,"up":true,"wheels":{}}"#, 2, "unknown key \"wheels\""),
        (start + "\n" + #"{"t_ms":0,"up":true,"down":"left"}"#, 2, "exactly one"),
        (start + "\n" + #"{"t_ms":0}"#, 2, "has none"),
        (start + "\n" + #"{"t_ms":0,"move":{"dx":128,"dy":0}}"#, 2, "move.dx is 128"),
        (start + "\n" + #"{"t_ms":0,"move":{"dx":1}}"#, 2, "\"dy\" is missing"),
        (start + "\n" + #"{"t_ms":0,"move":{"dx":1,"dy":0,"x":3}}"#, 2, "unknown key \"x\""),
        (start + "\n" + #"{"t_ms":-1,"up":true}"#, 2, "0 through 3600000"),
        (start + "\n" + #"{"t_ms":1e13,"up":true}"#, 2, "0 through 3600000"),
        (start + "\n" + #"{"t_ms":0,"up":false}"#, 2, "\"up\":true"),
        (start + "\n" + #"{"t_ms":0,"down":"thumb"}"#, 2, "down"),
        (start + "\n" + #"{"t_ms":5,"up":true}"# + "\n" + #"{"t_ms":4,"up":true}"#, 3, "goes backwards"),
        (start + "\n" + #"{"t_ms":0,"down":"right"}"# + "\n" + #"{"t_ms":1,"move":{"dx":1,"dy":1}}"#, 3, "ends with button 2 held"),
    ])
    func aScriptThatCannotBePlayedWholeIsRefusedAtItsLine(script: String, line: Int, saying: String) throws {
        let refused = try #require(throws: Play.ScriptInvalid.self) { try Play.parse(script) }
        #expect(refused.line == line)
        #expect(refused.reason.contains(saying), "\(refused)")
    }
}

/// The player against a clock the test moves and a mouse that costs time per report.
@Suite @MainActor struct PlayerTests {
    static let epoch: Int64 = 1_700_000_000_000_000

    /// Reports are due at their offsets from one start, not from each other: a report the
    /// mouse took 3 ms to acknowledge makes the next one late, and the one after it, due
    /// later than that, still goes out on time.
    @Test func eachReportGoesOutAtItsOwnDeadlineAndALateOneIsSentLate() async throws {
        let clock = ManualClock()
        let fake = FakeMouse(at: ScreenPoint(x: 10, y: 10))
        let mouse = CostlyMouse(mouse: fake, clock: clock, cost: .milliseconds(3))
        let play = try Play.parse("""
            {"to":{"x":10,"y":10}}
            {"t_ms":0,"down":"left"}
            {"t_ms":1,"move":{"dx":5,"dy":0}}
            {"t_ms":10,"up":true}
            """)
        let played = try await Player(pointer: Pointer(mouse: mouse, cursor: fake.cursor, locate: fake.locate), clock: clock, wall: { Self.epoch }, lead: .zero).play(play)
        #expect(played.startReports == 0)
        #expect(played.reports == [
            Played.Report(scheduled: Self.epoch, sent: Self.epoch, acked: Self.epoch + 3000),
            Played.Report(scheduled: Self.epoch + 1000, sent: Self.epoch + 3000, acked: Self.epoch + 6000),
            Played.Report(scheduled: Self.epoch + 10000, sent: Self.epoch + 10000, acked: Self.epoch + 13000),
        ])
        #expect(played.lateness.ranks == [0, 2000, 2000, 2000])
        #expect(fake.log == ["check", "check", "down 1", "check", "move 5 0", "check", "check", "up"])
        // Only the last report was still ahead of the clock: the first was due at the
        // start and the second overdue, and neither paid for a sleep.
        #expect(clock.sleeps == 1)
    }

    /// A long wait asks the mouse's check every slice, so a refusal during a minute's hold
    /// ends it one slice in and releases the button, not a minute later.
    @Test func aLongWaitIsStoppedWithinASlice() async throws {
        let clock = ManualClock()
        let fake = FakeMouse(at: ScreenPoint(x: 0, y: 0))
        fake.allow = 4
        let play = try Play.parse("""
            {"to":{"x":0,"y":0}}
            {"t_ms":0,"down":"left"}
            {"t_ms":60000,"up":true}
            """)
        let stopped = try await #require(throws: PlayStopped.self) {
            try await Player(pointer: fake.pointer, clock: clock, wall: { Self.epoch }, lead: .zero).play(play)
        }
        #expect(stopped.played.count == 1)
        #expect(clock.now.offset == Player<ManualClock>.slice)
        #expect(fake.log == ["check", "check", "down 1", "check", "check", "up"])
    }

    @Test func latenessIsReadByNearestRank() {
        #expect(Lateness(of: (1...100).map(Int64.init).shuffled()).ranks == [50, 90, 99, 100])
        #expect(Lateness(of: [7]).ranks == [7, 7, 7, 7])
    }

    /// A refused report stops the play with what went out before it, releases every
    /// button, and says when that release was refused too.
    @Test func aStopSaysHowFarThePlayGotAndReleases() async throws {
        let clock = ManualClock()
        let fake = FakeMouse(at: ScreenPoint(x: 0, y: 0))
        fake.allow = 5
        let play = try Play.parse("""
            {"to":{"x":0,"y":0}}
            {"t_ms":0,"down":"left"}
            {"t_ms":1,"move":{"dx":5,"dy":0}}
            {"t_ms":2,"up":true}
            """)
        let stopped = try await #require(throws: PlayStopped.self) {
            try await Player(pointer: fake.pointer, clock: clock, wall: { Self.epoch }, lead: .zero).play(play)
        }
        #expect(stopped.played.count == 1)
        #expect(stopped.of == 3)
        #expect(stopped.causes.contains { $0 is Refused })
        #expect("\(stopped)".contains("after 1 of 3 reports"))
        #expect("\(stopped)".contains("A button may be left held"))
        #expect(fake.log == ["check", "check", "down 1", "check", "check", "move 5 0", "up"])
    }
}

extension Lateness {
    var ranks: [Int64] { [p50, p90, p99, max] }
}

/// A mouse whose every report takes `cost` on the clock, as a helper round trip does.
@MainActor
struct CostlyMouse: Mouse {
    let mouse: FakeMouse
    let clock: ManualClock
    let cost: Duration

    func check() throws { try mouse.check() }
    func down(_ button: Button) async throws { clock.advance(by: cost); try mouse.down(button) }
    func releaseAll() async throws { clock.advance(by: cost); try mouse.releaseAll() }
    func move(by delta: Move) async throws { clock.advance(by: cost); try mouse.move(by: delta) }
    func scroll(by delta: Scroll) async throws { clock.advance(by: cost); try mouse.scroll(by: delta) }
}

/// A clock that moves only when told to, or when something sleeps until later than now.
final class ManualClock: Clock {
    struct Instant: InstantProtocol {
        let offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private let current = Mutex(Instant(offset: .zero))
    private let slept = Mutex(0)

    var now: Instant { current.withLock { $0 } }
    var minimumResolution: Duration { .zero }
    /// How many times something has slept on this clock.
    var sleeps: Int { slept.withLock { $0 } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        slept.withLock { $0 += 1 }
        current.withLock { $0 = Swift.max($0, deadline) }
    }

    func advance(by duration: Duration) {
        current.withLock { $0 = $0.advanced(by: duration) }
    }
}
