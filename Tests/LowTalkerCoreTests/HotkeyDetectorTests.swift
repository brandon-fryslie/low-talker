import LowTalkerCore
import Testing

private let rightOption = KeyChord(modifiers: .rightOption)
private let command = KeyChord(modifiers: .rightOption, .leftShift)
private let optionSpace = KeyChord(key: Key(rawValue: 49), modifiers: [.leftOption])
private let letterA = Key(rawValue: 0)

/// A keyboard the test types on, event by event, at the moments it says.
private struct Keyboard {
    var detector: HotkeyDetector
    /// The modifiers down right now, so each event reports the whole state the way
    /// the window server does.
    private var held: Set<Modifier> = []

    init(chords: Set<KeyChord> = [rightOption], tapThreshold: Duration = .milliseconds(250)) {
        detector = HotkeyDetector(chords: chords, tapThreshold: tapThreshold)
    }

    mutating func press(_ modifier: Modifier, at ms: Int64) -> HotkeyDetector.Verdict {
        held.insert(modifier)
        return detector.handle(KeyEvent(key: .modifier(modifier), direction: .down, modifiers: held, time: .milliseconds(ms)))
    }

    mutating func release(_ modifier: Modifier, at ms: Int64) -> HotkeyDetector.Verdict {
        held.remove(modifier)
        return detector.handle(KeyEvent(key: .modifier(modifier), direction: .up, modifiers: held, time: .milliseconds(ms)))
    }

    mutating func press(_ key: Key, at ms: Int64) -> HotkeyDetector.Verdict {
        detector.handle(KeyEvent(key: .key(key), direction: .down, modifiers: held, time: .milliseconds(ms)))
    }

    mutating func release(_ key: Key, at ms: Int64) -> HotkeyDetector.Verdict {
        detector.handle(KeyEvent(key: .key(key), direction: .up, modifiers: held, time: .milliseconds(ms)))
    }
}

private func began(_ chord: KeyChord) -> HotkeyDetector.Verdict { .init(transition: .began(chord), delivery: .swallow) }
private func ended(_ chord: KeyChord, _ press: PressKind) -> HotkeyDetector.Verdict { .init(transition: .ended(chord, press), delivery: .swallow) }
private let swallowed = HotkeyDetector.Verdict(transition: nil, delivery: .swallow)
private let passed = HotkeyDetector.Verdict(transition: nil, delivery: .pass)

@Suite struct HotkeyDetectorTests {
    @Test func aPressReleasedAfterTheThresholdIsAHold() {
        var keyboard = Keyboard()
        #expect(keyboard.press(.rightOption, at: 0) == began(rightOption))
        #expect(keyboard.detector.phase == .held(rightOption, since: .zero))
        #expect(keyboard.release(.rightOption, at: 400) == ended(rightOption, .hold))
        #expect(keyboard.detector.phase == .idle)
    }

    /// A tap leaves listening on; the next press of the chord ends it, and that press
    /// is consumed whole, however long it lasts.
    @Test func aPressReleasedWithinTheThresholdLatchesUntilTheNextPress() {
        var keyboard = Keyboard()
        #expect(keyboard.press(.rightOption, at: 0) == began(rightOption))
        #expect(keyboard.release(.rightOption, at: 100) == swallowed)
        #expect(keyboard.detector.phase == .latched(rightOption))
        #expect(keyboard.press(.rightOption, at: 5000) == ended(rightOption, .tap))
        #expect(keyboard.detector.phase == .idle)
        #expect(keyboard.release(.rightOption, at: 6000) == swallowed)
        #expect(keyboard.detector.phase == .idle)
    }

    @Test func aPressExactlyAtTheThresholdIsAHold() {
        var keyboard = Keyboard()
        _ = keyboard.press(.rightOption, at: 10)
        #expect(keyboard.release(.rightOption, at: 260) == ended(rightOption, .hold))
    }

    @Test func theThresholdIsTheDetectorsToSet() {
        var keyboard = Keyboard(tapThreshold: .milliseconds(50))
        _ = keyboard.press(.rightOption, at: 0)
        #expect(keyboard.release(.rightOption, at: 100) == ended(rightOption, .hold))
    }

    /// Keys that are not the chord's go to the app untouched, whatever the phase.
    @Test func otherKeysPassThroughInEveryPhase() {
        var keyboard = Keyboard()
        #expect(keyboard.press(letterA, at: 0) == passed)
        #expect(keyboard.release(letterA, at: 10) == passed)
        _ = keyboard.press(.rightOption, at: 20)
        #expect(keyboard.press(letterA, at: 30) == passed)
        #expect(keyboard.release(letterA, at: 40) == passed)
        #expect(keyboard.press(.leftOption, at: 50) == passed)
        #expect(keyboard.release(.leftOption, at: 60) == passed)
        _ = keyboard.release(.rightOption, at: 70)
        #expect(keyboard.detector.phase == .latched(rightOption))
        #expect(keyboard.press(letterA, at: 80) == passed)
        #expect(keyboard.release(letterA, at: 90) == passed)
    }

    /// Right Option with Command already held is a different chord, and one that is
    /// not configured: the app sees both keys, down and up.
    @Test func theChordWithAnotherModifierHeldIsNotThePress() {
        var keyboard = Keyboard()
        #expect(keyboard.press(.leftCommand, at: 0) == passed)
        #expect(keyboard.press(.rightOption, at: 10) == passed)
        #expect(keyboard.detector.phase == .idle)
        #expect(keyboard.release(.rightOption, at: 400) == passed)
        #expect(keyboard.release(.leftCommand, at: 410) == passed)
    }

    /// The chord that began the press owns it: adding Shift to a held Right Option
    /// changes nothing, though Right Option with Shift is itself a chord.
    @Test func aChordCompletedOnTopOfAHeldOneIsIgnored() {
        var keyboard = Keyboard(chords: [rightOption, command])
        #expect(keyboard.press(.rightOption, at: 0) == began(rightOption))
        #expect(keyboard.press(.leftShift, at: 100) == passed)
        #expect(keyboard.detector.phase == .held(rightOption, since: .zero))
        #expect(keyboard.release(.leftShift, at: 200) == passed)
        #expect(keyboard.release(.rightOption, at: 400) == ended(rightOption, .hold))
    }

    /// Shift first, then Right Option, is the two-key chord: the key that completed it
    /// is swallowed, the one the app already saw go down is passed back up, and
    /// releasing either ends the press.
    @Test func theOrderOfKeysPicksTheChord() {
        var keyboard = Keyboard(chords: [rightOption, command])
        #expect(keyboard.press(.leftShift, at: 0) == passed)
        #expect(keyboard.press(.rightOption, at: 10) == began(command))
        #expect(keyboard.release(.leftShift, at: 400) == HotkeyDetector.Verdict(transition: .ended(command, .hold), delivery: .pass))
        #expect(keyboard.detector.phase == .idle)
        #expect(keyboard.release(.rightOption, at: 410) == swallowed)
    }

    /// The two-key chord released on the key the app saw go down, within the
    /// threshold, latches like any tap, and that release is passed back as its down was.
    @Test func releasingTheUnswallowedKeyOfAChordWithinTheThresholdLatches() {
        var keyboard = Keyboard(chords: [rightOption, command])
        _ = keyboard.press(.leftShift, at: 0)
        #expect(keyboard.press(.rightOption, at: 10) == began(command))
        #expect(keyboard.release(.leftShift, at: 100) == passed)
        #expect(keyboard.detector.phase == .latched(command))
        #expect(keyboard.release(.rightOption, at: 110) == swallowed)
        #expect(keyboard.detector.phase == .latched(command))
    }

    /// A chord with a key completes on the key, with the modifiers already held, and
    /// its repeats while held are swallowed with it.
    @Test func aChordWithAKeyCompletesOnTheKeyAndSwallowsItsRepeats() {
        var keyboard = Keyboard(chords: [optionSpace])
        #expect(keyboard.press(.leftOption, at: 0) == passed)
        #expect(keyboard.press(Key(rawValue: 49), at: 10) == began(optionSpace))
        #expect(keyboard.press(Key(rawValue: 49), at: 500) == swallowed)
        #expect(keyboard.release(Key(rawValue: 49), at: 600) == ended(optionSpace, .hold))
        #expect(keyboard.release(.leftOption, at: 610) == passed)
    }

    /// Any key of the pressed chord coming up ends the press, the modifier included;
    /// the key it completed on is still swallowed when it comes up later.
    @Test func releasingTheModifierOfAKeyChordEndsThePress() {
        var keyboard = Keyboard(chords: [optionSpace])
        _ = keyboard.press(.leftOption, at: 0)
        _ = keyboard.press(Key(rawValue: 49), at: 10)
        #expect(keyboard.release(.leftOption, at: 400) == HotkeyDetector.Verdict(transition: .ended(optionSpace, .hold), delivery: .pass))
        #expect(keyboard.detector.phase == .idle)
        #expect(keyboard.release(Key(rawValue: 49), at: 410) == swallowed)
    }

    /// A press can begin while the last one's swallowed key is still down: that key's
    /// up is swallowed whenever it comes, so the app never sees an up without its down.
    @Test func aNewPressKeepsSwallowingTheLastOnesKeyUntilItComesUp() {
        var keyboard = Keyboard(chords: [optionSpace, rightOption])
        _ = keyboard.press(.leftOption, at: 0)
        #expect(keyboard.press(Key(rawValue: 49), at: 10) == began(optionSpace))
        #expect(keyboard.release(.leftOption, at: 400) == HotkeyDetector.Verdict(transition: .ended(optionSpace, .hold), delivery: .pass))
        #expect(keyboard.press(.rightOption, at: 410) == began(rightOption))
        #expect(keyboard.release(Key(rawValue: 49), at: 420) == swallowed)
        #expect(keyboard.release(.rightOption, at: 800) == ended(rightOption, .hold))
    }

    @Test func aChordWithAKeyIsNotCompletedByItsModifier() {
        var keyboard = Keyboard(chords: [optionSpace])
        #expect(keyboard.press(Key(rawValue: 49), at: 0) == passed)
        #expect(keyboard.press(.leftOption, at: 10) == passed)
        #expect(keyboard.detector.phase == .idle)
    }

    /// A lapse ends whatever press is open, a hold or a latched tap, and swallows
    /// nothing further: the key that comes up afterwards reaches the app.
    @Test func aLapseEndsWhateverPressIsOpen() {
        var keyboard = Keyboard()
        #expect(keyboard.detector.lapse() == nil)
        _ = keyboard.press(.rightOption, at: 0)
        #expect(keyboard.detector.lapse() == .ended(rightOption, .hold))
        #expect(keyboard.detector.phase == .idle)
        #expect(keyboard.release(.rightOption, at: 10) == passed)
        _ = keyboard.press(.rightOption, at: 100)
        _ = keyboard.release(.rightOption, at: 150)
        #expect(keyboard.detector.lapse() == .ended(rightOption, .tap))
        #expect(keyboard.detector.phase == .idle)
    }

    /// While latched, any configured chord ends the listening, not only the one that
    /// began it.
    @Test func anyChordPressEndsALatchedSession() {
        var keyboard = Keyboard(chords: [rightOption, command])
        _ = keyboard.press(.rightOption, at: 0)
        _ = keyboard.release(.rightOption, at: 100)
        _ = keyboard.press(.leftShift, at: 1000)
        #expect(keyboard.press(.rightOption, at: 1010) == ended(rightOption, .tap))
    }
}
