import Keystrokes

/// The keyboard one character is typed on: keys that go down, a release that takes them
/// all back up, and the refusal that guards every one of them.
///
/// [LAW:effects-at-boundaries] Posting a key is an effect against the driver and the
/// refusal reads the window server, so both sit behind this seam - which is what lets a
/// test throw at the third keystroke of a four-keystroke character and read back the
/// score the run would have reported, without a driver or an app in front.
///
/// Main-actor, because the refusal reads which app is in front and that is a question
/// only the main actor may ask.
@MainActor
protocol Keyboard {
    /// Throws rather than let the next keystroke be posted: the operator interrupted, or
    /// the target app is no longer frontmost. One member and not two, because a keystroke
    /// that must not be posted and a keystroke that fails to post are the same event to
    /// everything downstream. [LAW:one-type-per-behavior]
    func check() throws
    func down(_ usage: Usage) throws
    func releaseAll() throws
}

/// Types characters and keeps the score a stopped run has to report.
///
/// A character is several keystrokes - a dead key and the letter it accents, a modifier
/// and the key under it - so a run can stop *inside* one, and which keystrokes had been
/// posted decides both how much is on screen and whether the app is left holding a
/// pending accent. That is the entire content of a failure report, so it is a value that
/// can be driven and read rather than two variables in a run loop.
@MainActor
struct Scribe {
    let keyboard: any Keyboard

    /// Characters posted and acknowledged. "Posted and acknowledged", not "typed": the
    /// daemon acknowledges reports the driver then drops, so this is an upper bound on
    /// what landed and never a delivery receipt.
    private(set) var typed = 0

    /// A character whose first keystroke landed and whose last did not. Only a run that
    /// stopped inside a character has one, and the target app is then holding a pending
    /// accent that the next keystroke it receives - a retry, another run, the operator's
    /// own hands - will combine with into some other character. Nothing here can undo a
    /// posted keystroke, so this is said rather than fixed.
    private(set) var halfTyped: Character?

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
    /// `composing` is the character this key leaves pending in the app - the dead key of
    /// an accented letter, and nothing else. It travels with the call rather than being set
    /// beside it, so the one line that can record a pending accent is the one line that is
    /// ambiguous about whether it happened. [LAW:dataflow-not-control-flow]
    private mutating func press(_ usage: Usage, composing pending: Character?) throws {
        try keyboard.check()
        // Recorded between the check and the down, and cleared after the character's last
        // key comes back. The two failures are not the same thing and must not report the
        // same thing: a `down` that throws may still have reached the driver, so its accent
        // is assumed pending rather than assumed away - the bias `keysDown` keeps, for the
        // same reason - while a `check` that throws is a local decision that sent nothing,
        // and reporting an accent for it would tell the operator to clear a composition
        // that is not there.
        if let pending { halfTyped = pending }
        try keyboard.down(usage)
    }

    mutating func press(_ character: Character, _ keystrokes: [Keystroke]) throws {
        for (index, keystroke) in keystrokes.enumerated() {
            for modifier in keystroke.modifiers.usages { try press(modifier, composing: nil) }
            let last = index == keystrokes.count - 1
            try press(keystroke.usage, composing: last ? nil : character)
            // Counted on the key-down the daemon has acknowledged, not after the release:
            // a failure between the two still put the character on screen, and a count
            // taken after the release would report one fewer than is really there. It is
            // the LAST key-down of the character, because a character typed as a dead key
            // and then the letter it accents is not on screen until the second of them.
            //
            // The opposite bias to `halfTyped` above, and deliberately: this count says
            // "posted and acknowledged", which a throw means did not happen, while that
            // says "may be pending", which a throw means it might be.
            if last {
                typed += 1
                halfTyped = nil
            }
            try keyboard.releaseAll()
        }
    }
}
