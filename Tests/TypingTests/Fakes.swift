import CoreGraphics
import Keystrokes
import LowTalkerCore
import Pointing
import Synchronization
import Typing

/// A keyboard that records what it was asked to do and refuses after a given number of
/// calls, so a run can be stopped at any point inside a character.
///
/// One knob and not three: every call goes through the same counter, so "throw on the
/// second key-down of a two-keystroke character" and "throw on the release after it" are
/// the same test with a different number. [LAW:no-mode-explosion]
@MainActor
final class RefusingKeyboard: Keyboard {
    private(set) var log: [String] = []
    /// How many calls to let through before refusing every one after.
    var allow = Int.max

    private func record(_ what: String) throws {
        guard log.count < allow else { throw Refused() }
        log.append(what)
    }

    func check() throws { try record("check") }
    func down(_ usage: Usage) throws { try record("down \(String(usage.rawValue, radix: 16))") }
    func releaseAll() throws { try record("up") }
}

/// A keyboard whose keys will not go down but whose release still answers: the daemon
/// that refuses a report and acknowledges the release after it.
@MainActor
final class StuckKeyboard: Keyboard {
    private(set) var log: [String] = []

    func check() throws { log.append("check") }
    func down(_ usage: Usage) throws {
        log.append("down \(String(usage.rawValue, radix: 16))")
        throw Refused()
    }
    func releaseAll() throws { log.append("up") }
}

struct Refused: Error {}

/// A pointing device that records every report reaching it. Where `FakeMouse` stands in
/// for the whole mouse, this stands under one - so a test can ask not only whether a
/// refusal was raised but whether anything reached the device before it.
///
/// Not `@MainActor`, because `Pointing` is not: it is the seam under the mouse, shared with
/// the helper, and a guarded mouse calls it from the queue it waits on. So the log is
/// behind a lock, as `VirtualPointing`'s record is.
final class RecordingPointing: Pointing {
    private let recorded = Mutex<[String]>([])

    var log: [String] { recorded.withLock { $0 } }

    func down(_ button: Button) throws { recorded.withLock { $0.append("down \(button.rawValue)") } }
    func releaseAll() throws { recorded.withLock { $0.append("up") } }
    func move(by delta: Move) throws { recorded.withLock { $0.append("move \(delta.x.value) \(delta.y.value)") } }
    func scroll(by delta: Scroll) throws { recorded.withLock { $0.append("scroll \(delta.vertical.value) \(delta.horizontal.value)") } }
}

/// A mouse on a screen of its own, recording every report. The cursor moves by what a
/// report asks times a curve standing in for the OS's acceleration - three points a
/// count when the report is fast, one when it is slow - so the pointer's loop is tested
/// against the thing it exists for, and its steps can be read back one by one.
///
/// The refusal logs the call and then refuses it: the daemon takes the report and
/// answers no, and the log says what was posted before it did. [LAW:no-silent-failure]
@MainActor
final class FakeMouse: Mouse {
    private(set) var log: [String] = []
    /// How many calls to accept before every one after is logged and refused.
    var allow = Int.max
    var position: ScreenPoint
    /// What is on the screen, by "role/title".
    var elements: [String: CGRect] = [:]
    /// A cursor pinned in place: every report is posted and moves nothing.
    var stuck = false

    init(at position: ScreenPoint) { self.position = position }

    private func record(_ what: String) throws {
        log.append(what)
        guard log.count <= allow else { throw Refused() }
    }

    func check() throws { try record("check") }
    func down(_ button: Button) throws { try record("down \(button.rawValue)") }
    func releaseAll() throws { try record("up") }

    func move(by delta: Move) throws {
        try record("move \(delta.x.value) \(delta.y.value)")
        let gain = gain(of: delta)
        position = ScreenPoint(x: position.x + Double(delta.x.value) * gain, y: position.y + Double(delta.y.value) * gain)
    }

    /// Points per count for one report: the curve's knee is at ten counts.
    private func gain(of delta: Move) -> Double {
        guard !stuck else { return 0 }
        return max(abs(Int(delta.x.value)), abs(Int(delta.y.value))) > 10 ? 3 : 1
    }

    func scroll(by delta: Scroll) throws { try record("scroll \(delta.vertical.value) \(delta.horizontal.value)") }

    func cursor() throws -> ScreenPoint { position }

    func locate(_ role: AccessibilityRole, _ title: String) throws -> CGRect {
        guard let frame = elements["\(role.rawValue)/\(title)"] else {
            throw ScreenUnreadable.noElement(role: role.rawValue, title: title, app: "the fake screen")
        }
        return frame
    }

    /// The pointer over this mouse, reading this screen.
    var pointer: Pointer { Pointer(mouse: self, cursor: cursor, locate: locate) }
}
