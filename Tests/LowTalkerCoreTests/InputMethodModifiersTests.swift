import Flavors
import LowTalkerCore
import Testing

/// The input method's hearing, held through the press detection it feeds: a stream of the
/// modifier keys held, as the input method tells them, becomes presses.
///
/// Driven by states rather than by keys, because states are what cross from the input
/// method, told as often as the app it was in hands them over. [LAW:behavior-not-structure]
private struct Told {
    var detector: HotkeyDetector
    private var told = ToldModifiers(held: [])

    init(listeningFor flavor: Flavor) {
        detector = HotkeyDetector(chords: [Hotkey.defaultChord(for: flavor)], tapThreshold: .milliseconds(250))
    }

    /// The input method telling the app that `modifiers` are held, `ms` into the run.
    mutating func holding(_ modifiers: Set<Modifier>, at ms: Int64) -> [HotkeyDetector.Transition] {
        heard(told.take(modifiers, at: at(ms)))
    }

    /// The app reading the session's modifier keys itself, `ms` into the run.
    mutating func session(_ modifiers: Set<Modifier>, at ms: Int64) -> [HotkeyDetector.Transition] {
        heard(told.confirm(session: modifiers, at: at(ms)))
    }

    /// Each state in turn, and every press they made.
    mutating func told(_ states: [(Set<Modifier>, Int64)]) -> [HotkeyDetector.Transition] {
        states.flatMap { holding($0.0, at: $0.1) }
    }

    private mutating func heard(_ moves: [KeyEvent]) -> [HotkeyDetector.Transition] {
        moves.compactMap { detector.handle($0) }
    }
}

private func at(_ ms: Int64) -> HostTime { HostTime(uptime: .milliseconds(ms)) }

private let release = KeyChord(modifiers: .rightOption)
private let development = KeyChord(modifiers: .rightOption, .rightCommand)

@Suite struct InputMethodModifiersTests {
    @Test func aHoldBeginsAtThePressAndEndsAtTheRelease() {
        var told = Told(listeningFor: .release)
        #expect(told.told([([.rightOption], 0), ([], 600)]) == [.began(release, at: at(0)), .ended(release, .released(.hold))])
    }

    @Test func aTapLatchesUntilTheNextPress() {
        var told = Told(listeningFor: .release)
        #expect(told.told([([.rightOption], 0), ([], 100)]) == [.began(release, at: at(0))])
        #expect(told.told([([.rightOption], 2000), ([], 2100)]) == [.ended(release, .released(.tap))])
    }

    /// VS Code hands the input method every change twice, measured on studious,
    /// 2026-09-27, and a tap told twice is still one tap: the second telling of a state
    /// already held changes nothing, where a second key-down would have ended the latch and
    /// begun a new press on the spot.
    @Test func aStateToldTwiceIsToldOnce() {
        var once = Told(listeningFor: .release)
        var twice = Told(listeningFor: .release)
        let states: [(Set<Modifier>, Int64)] = [([.rightOption], 0), ([], 100), ([.rightOption], 2000), ([], 2100)]
        #expect(twice.told(states.flatMap { [$0, ($0.0, $0.1 + 3)] }) == once.told(states))
    }

    /// Right Option pressed with Shift already down is another chord, and passes by.
    @Test func anotherModifierHeldFirstMakesItAnotherChord() {
        var told = Told(listeningFor: .release)
        #expect(told.told([([.leftShift], 0), ([.leftShift, .rightOption], 50), ([.rightOption], 100), ([], 700)]).isEmpty)
    }

    /// Shift added and let go during a hold changes nothing: the press is the chord's.
    @Test func anotherModifierDuringAHoldChangesNothing() {
        var told = Told(listeningFor: .release)
        #expect(told.told([([.rightOption], 0), ([.rightOption, .leftShift], 200), ([.rightOption], 300), ([], 600)])
            == [.began(release, at: at(0)), .ended(release, .released(.hold))])
    }

    /// The development chord is Right Command then Right Option, and the release copy
    /// hears nothing of it.
    @Test func theOtherInstallationsChordIsIgnored() {
        var releaseCopy = Told(listeningFor: .release)
        var developmentCopy = Told(listeningFor: .development)
        let states: [(Set<Modifier>, Int64)] = [([.rightCommand], 0), ([.rightCommand, .rightOption], 50), ([], 700)]
        #expect(releaseCopy.told(states).isEmpty)
        #expect(developmentCopy.told(states) == [.began(development, at: at(50)), .ended(development, .released(.hold))])
    }

    /// Both keys of the development chord arriving in one state - pressed inside the moment
    /// the input method took to read it - still make the development press and not the
    /// release one, since the key the release chord shares goes down last.
    @Test func twoKeysDownInOneStateAreNotTheOtherInstallationsChord() {
        var releaseCopy = Told(listeningFor: .release)
        var developmentCopy = Told(listeningFor: .development)
        let states: [(Set<Modifier>, Int64)] = [([.rightCommand, .rightOption], 0), ([], 700)]
        #expect(releaseCopy.told(states).isEmpty)
        #expect(developmentCopy.told(states) == [.began(development, at: at(0)), .ended(development, .released(.hold))])
    }

    /// A release the input method was never handed - focus moved to where it hears nothing
    /// - is heard in the next state it is told, which no longer holds the key, rather than
    /// leaving the microphone open until the chord is pressed again.
    @Test func aReleaseThatWasNotToldIsHeardInTheNextState() {
        var told = Told(listeningFor: .release)
        #expect(told.told([([.rightOption], 0), ([.leftShift], 900)])
            == [.began(release, at: at(0)), .ended(release, .released(.hold))])
    }

    /// A release the input method is never told at all - let go over the Desktop, or its
    /// message dropped on a full port - is heard when the app reads the session, not left to
    /// hold the microphone open.
    @Test func aReleaseTheSessionNoLongerHoldsIsHeard() {
        var told = Told(listeningFor: .release)
        #expect(told.holding([.rightOption], at: 0) == [.began(release, at: at(0))])
        #expect(told.session([], at: 800) == [.ended(release, .released(.hold))])
    }

    /// The session only confirms: a key down there that the input method never told is not
    /// a press, since the input method is what hears presses.
    @Test func theSessionCannotPress() {
        var told = Told(listeningFor: .release)
        #expect(told.holding([.leftShift], at: 0).isEmpty)
        #expect(told.session([.leftShift, .rightOption], at: 200).isEmpty)
        #expect(told.holding([], at: 300).isEmpty)
    }

    /// The input method's message about a hold, arriving after the session was read letting
    /// go of it, is older than that release and does not press the key again.
    @Test func aStateOlderThanTheSessionsReleaseDoesNotPressItAgain() {
        var told = Told(listeningFor: .release)
        #expect(told.holding([.rightOption], at: 0) == [.began(release, at: at(0))])
        #expect(told.session([], at: 800) == [.ended(release, .released(.hold))])
        #expect(told.holding([.rightOption], at: 700).isEmpty)
        #expect(told.holding([.rightOption], at: 2000) == [.began(release, at: at(2000))])
    }

    /// Shift let go and Right Option pressed inside one of the app's session reads: the read
    /// lets go of Shift before the input method's messages arrive, and the press they carry,
    /// stamped before the read, is still heard.
    @Test func aPressStampedBeforeTheSessionsReadIsStillHeard() {
        var told = Told(listeningFor: .release)
        #expect(told.holding([.leftShift], at: 0).isEmpty)
        #expect(told.session([.rightOption], at: 1002).isEmpty)
        #expect(told.holding([], at: 990).isEmpty)
        #expect(told.holding([.rightOption], at: 1000) == [.began(release, at: at(1000))])
        #expect(told.holding([], at: 1700) == [.ended(release, .released(.hold))])
    }

    /// The development chord completed while a session read let go of nothing in between
    /// still presses: a read that changes nothing marks nothing.
    @Test func aSessionReadThatLetGoOfNothingOvertakesNothing() {
        var told = Told(listeningFor: .development)
        #expect(told.holding([.rightCommand], at: 0).isEmpty)
        #expect(told.session([.rightCommand, .rightOption], at: 1002).isEmpty)
        #expect(told.holding([.rightCommand, .rightOption], at: 1000) == [.began(development, at: at(1000))])
    }

    @Test func aStateThatChangedNothingIsNoKeys() {
        #expect(KeyEvent.moves(from: [.rightOption], to: [.rightOption], at: at(0)).isEmpty)
    }
}
