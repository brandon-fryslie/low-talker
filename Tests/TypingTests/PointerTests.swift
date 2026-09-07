import CoreGraphics
import LowTalkerCore
import Pointing
import Testing
@testable import Typing

/// The pointer against a fake screen with a fake acceleration curve: what the loop posts,
/// where the cursor ends up, and what it does when the cursor will not go.
@Suite @MainActor struct PointerTests {
    static let origin = ScreenPoint(x: 0, y: 0)
    static let button = AccessibilityRole(rawValue: "AXButton")

    /// One step is the remaining distance over the gain, rounded toward zero and clamped to
    /// the report: the whole screen at gain one is a full report, and 160.5 at gain three
    /// asks for 53, not 54, so a known gain lands short and never past.
    @Test func aStepIsTheRemainingDistanceOverTheGainClampedToTheReport() {
        #expect(Pointer.step(from: Self.origin, to: ScreenPoint(x: 541.5, y: 375), gain: 1) == Move(x: Count(clamping: 127), y: Count(clamping: 127)))
        #expect(Pointer.step(from: Self.origin, to: ScreenPoint(x: 160.5, y: -6), gain: 3) == Move(x: Count(clamping: 53), y: Count(clamping: -2)))
        #expect(Pointer.step(from: ScreenPoint(x: 100, y: 100), to: ScreenPoint(x: 90, y: 100), gain: 1) == Move(x: Count(clamping: -10), y: .zero))
    }

    /// Within half a point an axis is arrived and asks for nothing; outside it the ask is
    /// never rounded to nothing, however high the gain.
    @Test func aStepIsZeroWhenArrivedAndNeverZeroWhenNot() {
        #expect(Pointer.step(from: Self.origin, to: ScreenPoint(x: 0.4, y: -0.5), gain: 1) == .none)
        #expect(Pointer.step(from: Self.origin, to: ScreenPoint(x: 1, y: -0.6), gain: 10) == Move(x: Count(clamping: 1), y: Count(clamping: -1)))
    }

    /// The gain is what moved over what was asked; a report that moved nothing halves the
    /// estimate rather than zeroing it, so the next ask doubles.
    @Test func theGainIsObservedMotionOverAskedMotion() {
        let asked = Move(x: Count(clamping: 127), y: Count(clamping: 127))
        #expect(Pointer.gain(after: asked, from: Self.origin, to: ScreenPoint(x: 381, y: 381), previous: 1) == 3)
        #expect(Pointer.gain(after: asked, from: Self.origin, to: Self.origin, previous: 1) == 0.5)
    }

    /// A move across the screen: the first full report is thrown by the curve, the loop
    /// reads the gain off it and lands short with the second, a one-count nudge finishes,
    /// and the arrival round still asks the check.
    @Test func aMoveLearnsTheGainAndConvergesFromBelow() throws {
        let mouse = FakeMouse(at: ScreenPoint(x: 100, y: 100))
        let reports = try mouse.pointer.move(to: ScreenPoint(x: 641.5, y: 475))
        #expect(reports == 3)
        #expect(mouse.position == ScreenPoint(x: 641, y: 475))
        #expect(mouse.log == ["check", "move 127 127", "check", "move 53 -2", "check", "move 1 0", "check"])
    }

    /// A cursor that will not move is given three reports, each asking for more than the
    /// last, and then refused by name with where it is.
    @Test func aCursorThatWillNotMoveIsGivenUpAfterThreeStalls() throws {
        let mouse = FakeMouse(at: Self.origin)
        mouse.stuck = true
        let refused = try #require(throws: WouldNotReach.self) { try mouse.pointer.move(to: ScreenPoint(x: 50, y: 0)) }
        #expect(refused.reports == 3)
        #expect(refused.cursor == Self.origin)
        #expect(mouse.log == ["check", "move 50 0", "check", "move 100 0", "check", "move 127 0"])
    }

    /// Each click is a button down and a release, each behind its own check, after the
    /// move's own check found the cursor already there.
    @Test func aClickPostsOneDownAndOneUpPerClick() throws {
        let mouse = FakeMouse(at: Self.origin)
        let click = try mouse.pointer.click(at: Self.origin, button: .middle, times: Clicks(rawValue: 3)!)
        #expect(click == Pointer.Click(at: Self.origin, reports: 0))
        #expect(mouse.log == ["check", "check", "down 3", "up", "check", "down 3", "up", "check", "down 3", "up"])
    }

    /// A click that stops with the button down releases on the way out, and says so when
    /// the release was refused too. [LAW:no-silent-failure]
    @Test func aClickThatStopsReleasesAndReportsARefusedRelease() throws {
        let mouse = FakeMouse(at: Self.origin)
        mouse.allow = 3
        let stopped = try #require(throws: PointingStopped.self) { try mouse.pointer.click(at: Self.origin, button: .left, times: .single) }
        #expect(stopped.cause is Refused)
        #expect(stopped.unreleased != nil)
        #expect("\(stopped)".contains("A button may be left held"))
        #expect(mouse.log == ["check", "check", "down 1", "up", "up"])
    }

    /// The wheel goes out in reports of at most 127 on an axis, the remainder last.
    @Test func aScrollIsChunkedToTheReportsRange() throws {
        let mouse = FakeMouse(at: Self.origin)
        try mouse.pointer.scroll(at: Self.origin, vertical: WheelCounts(rawValue: 300)!, horizontal: WheelCounts(rawValue: -5)!)
        #expect(mouse.log == ["check", "check", "scroll 127 -5", "check", "scroll 127 0", "check", "scroll 46 0"])
    }

    /// An element is clicked at the centre of its frame, after the cursor is brought there:
    /// the first report overshoots before the gain is known, the second lands short.
    @Test func anElementIsClickedAtTheCentreOfItsFrame() throws {
        let mouse = FakeMouse(at: ScreenPoint(x: 600, y: 400))
        mouse.elements["AXButton/Cancel"] = CGRect(x: 641, y: 460, width: 113, height: 30)
        let click = try mouse.pointer.click(element: Self.button, title: "Cancel")
        #expect(click == Pointer.Click(at: ScreenPoint(x: 697.5, y: 475), reports: 3))
        #expect(mouse.log == ["check", "move 97 75", "check", "move -64 -50", "check", "move -1 0", "check", "check", "down 1", "up"])
    }

    /// An element with no area, or none at all, is refused before a report goes out.
    @Test func anElementWithoutAreaOrWithoutPresenceIsRefusedBeforeAnyReport() throws {
        let mouse = FakeMouse(at: Self.origin)
        mouse.elements["AXButton/Cancel"] = CGRect(x: 641, y: 460, width: 0, height: 30)
        #expect(throws: NoAreaToClick.self) { try mouse.pointer.click(element: Self.button, title: "Cancel") }
        #expect(throws: ScreenUnreadable.self) { try mouse.pointer.click(element: Self.button, title: "OK") }
        #expect(mouse.log.isEmpty)
    }
}
