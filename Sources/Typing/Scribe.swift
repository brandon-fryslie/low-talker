import Keystrokes

/// Presses keystrokes and keeps the score a stopped run has to report.
///
/// A character is several keystrokes - a dead key and the letter it accents, a modifier
/// and the key under it - so a run can stop *inside* one, and which keystrokes had been
/// posted decides both how much is on screen and whether the app is left holding a
/// pending accent. That is the entire content of a failure report, so it is a value that
/// can be driven and read rather than two variables in a run loop.
@MainActor
public struct Scribe {
    public let keyboard: any Keyboard

    public init(keyboard: any Keyboard) {
        self.keyboard = keyboard
    }

    /// Characters and chords posted and acknowledged. "Posted and acknowledged", not
    /// "typed": the daemon acknowledges reports the driver then drops, so this is an upper
    /// bound on what landed and never a delivery receipt.
    public private(set) var typed = 0

    /// A character whose first keystroke landed and whose last did not. Only a run that
    /// stopped inside a character has one, and the target app is then holding a pending
    /// accent that the next keystroke it receives - a retry, another run, the operator's
    /// own hands - will combine with into some other character. Nothing here can undo a
    /// posted keystroke, so this is said rather than fixed.
    public private(set) var halfTyped: Character?

    /// One key down, and the refusal that guards it.
    ///
    /// [LAW:single-enforcer] Every irrevocable act goes through here, and a keystroke is
    /// several of them: an em dash holds Shift and Option before its key, and each of those
    /// is its own report with its own round trip to the daemon. Checking once a keystroke
    /// left a window between the modifiers in which focus could move and the rest of the
    /// keystroke land in whatever app took the front - and then close again before the next
    /// check, so nothing ever reported it.
    ///
    /// `releaseAll` is deliberately not guarded this way. A release that refuses to run
    /// leaves a key down for macOS to repeat into whatever comes forward next, which is
    /// worse than what the check prevents: the check is what makes a refusal safe, so it
    /// cannot be what stops the release.
    ///
    /// `composing` is the character this key leaves pending in the app - the dead key of
    /// an accented letter, and nothing else. It travels with the call rather than being set
    /// beside it, so the one line that can record a pending accent is the one line that is
    /// ambiguous about whether it happened. [LAW:dataflow-not-control-flow]
    private mutating func down(_ usage: Usage, composing pending: Character?) async throws {
        try keyboard.check()
        // Recorded between the check and the down, and cleared after the character's last
        // key comes back. The two failures are not the same thing and must not report the
        // same thing: a `down` that throws may still have reached the driver, so its accent
        // is assumed pending rather than assumed away - the bias `keysDown` keeps, for the
        // same reason - while a `check` that throws is a local decision that sent nothing,
        // and reporting an accent for it would tell the operator to clear a composition
        // that is not there.
        if let pending { halfTyped = pending }
        try await keyboard.down(usage)
    }

    /// One keystroke: its modifiers down, the key down under them, everything up.
    ///
    /// A modifier is a key like any other to the device, held around the one it modifies,
    /// so a keystroke costs one report per modifier, one for the key, and one for the
    /// release - two for a bare letter, four for the em dash. That is the faithful count: a
    /// modifier and the key it modifies do not go down in the same scan on real hardware
    /// either.
    private mutating func press(_ keystroke: Keystroke, composing: Character?) async throws {
        for modifier in keystroke.modifiers.usages { try await down(modifier, composing: nil) }
        try await down(keystroke.usage, composing: composing)
        // Counted on the key-down the daemon has acknowledged, not after the release: a
        // failure between the two still put the character on screen, and a count taken
        // after the release would report one fewer than is really there. It is the LAST
        // key-down of the character - the one composing nothing - because a character
        // typed as a dead key and then the letter it accents is not on screen until the
        // second of them.
        //
        // The opposite bias to `halfTyped` above, and deliberately: this count says
        // "posted and acknowledged", which a throw means did not happen, while that says
        // "may be pending", which a throw means it might be.
        if composing == nil {
            typed += 1
            halfTyped = nil
        }
        try await keyboard.releaseAll()
    }

    /// A chord: one keystroke that is a whole act, so it composes nothing and counts as
    /// one when its key has gone down.
    public mutating func press(_ keystroke: Keystroke) async throws {
        try await press(keystroke, composing: nil)
    }

    /// A character, as the keystrokes the layout says it costs. Every keystroke but the
    /// last leaves the character pending in the app.
    public mutating func type(_ character: Character, _ keystrokes: [Keystroke]) async throws {
        for (index, keystroke) in keystrokes.enumerated() {
            try await press(keystroke, composing: index == keystrokes.count - 1 ? nil : character)
        }
    }
}
