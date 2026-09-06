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

    mutating func press(_ character: Character, _ keystrokes: [Keystroke]) throws {
        for (index, keystroke) in keystrokes.enumerated() {
            // Before every keystroke, not every character. A keystroke is irrevocable the
            // moment it is posted, so the window in which focus may move has to be one
            // keystroke wide - and an accented character is two keystrokes, so checking
            // once a character would let the letter half of it land in whatever app took
            // the front. [LAW:single-enforcer] [LAW:no-ambient-temporal-coupling]
            try keyboard.check()
            for modifier in keystroke.modifiers.usages { try keyboard.down(modifier) }
            let last = index == keystrokes.count - 1
            // Recorded BEFORE the key goes down, and cleared after the last one comes
            // back. A request that throws may still have reached the driver, so a dead key
            // whose post failed is assumed to be pending in the app rather than assumed
            // away - the same bias `keysDown` keeps, for the same reason.
            if !last { halfTyped = character }
            try keyboard.down(keystroke.usage)
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
