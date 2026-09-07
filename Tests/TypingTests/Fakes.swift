import Keystrokes
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
