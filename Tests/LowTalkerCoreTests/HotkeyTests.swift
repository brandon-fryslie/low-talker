import Choices
import Dispatch
import Flavors
import LowTalkerCore
import Testing

private struct Refused: Error, Equatable {}

/// A tap a test controls: the handler it was given is the test's to feed, and the
/// system switching it off is the test's to say.
@MainActor
private final class FakeTap: KeyboardTap {
    final class Installation {
        let chords: Set<KeyChord>
        let handle: @MainActor (KeyEvent) -> HotkeyDetector.Passage
        let onLapse: @MainActor (HostTime, LapseCause) -> LapseResponse
        var disposed = false

        init(chords: Set<KeyChord>, handle: @escaping @MainActor (KeyEvent) -> HotkeyDetector.Passage, onLapse: @escaping @MainActor (HostTime, LapseCause) -> LapseResponse) {
            self.chords = chords
            self.handle = handle
            self.onLapse = onLapse
        }
    }

    private(set) var installations: [Installation] = []
    private let refusal: (any Error)?

    init(refusing refusal: (any Error)? = nil) {
        self.refusal = refusal
    }

    func install(listeningFor chords: Set<KeyChord>, handling handle: @escaping @MainActor (KeyEvent) -> HotkeyDetector.Passage, onLapse: @escaping @MainActor (HostTime, LapseCause) -> LapseResponse) throws -> Disposal {
        if let refusal { throw refusal }
        let installation = Installation(chords: chords, handle: handle, onLapse: onLapse)
        installations.append(installation)
        return { installation.disposed = true }
    }
}

/// Lets the main queue run what the hotkey put on it.
///
/// The queue is first-in-first-out, so everything queued before this call has run by the
/// time it resumes. Waiting on the queue itself rather than on a duration, so the wait is
/// exactly as long as the work and a slow machine cannot make it flake.
/// [LAW:no-ambient-temporal-coupling]
private func settle() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

private let rightOption = KeyChord(modifiers: .rightOption)

private func at(_ ms: Int64) -> HostTime { HostTime(uptime: .milliseconds(ms)) }

private func rightOption(_ direction: KeyEvent.Direction, at ms: Int64) -> KeyEvent {
    KeyEvent(key: .modifier(.rightOption), direction: direction, modifiers: direction == .down ? [.rightOption] : [], time: at(ms))
}

@MainActor
@Suite struct HotkeyTests {
    @Test func aPressReachesTheHandlerAndIsSwallowed() async throws {
        let tap = FakeTap()
        let hotkey = Hotkey(chords: [rightOption], tap: tap)
        var transitions: [HotkeyDetector.Transition] = []
        try hotkey.start({ transitions.append($0) }, onLapse: { _ in })
        let installation = try #require(tap.installations.first)
        #expect(installation.handle(rightOption(.down, at: 0)) == .swallow)
        #expect(hotkey.phase == .held(rightOption, since: at(0)))
        await settle()
        #expect(transitions == [.began(rightOption, at: at(0))])
        #expect(installation.handle(rightOption(.up, at: 400)) == .swallow)
        await settle()
        #expect(transitions == [.began(rightOption, at: at(0)), .ended(rightOption, .released(.hold))])
    }

    /// **The callback answers the window server and does nothing else.**
    ///
    /// An active tap is a gate: every keystroke in the login session waits behind this
    /// callback until it returns, so a handler that opens a microphone or asks another
    /// process what is in front holds the whole machine's keyboard for as long as that
    /// takes. Run long enough and the system switches the tap off and throws away every
    /// key that queued in the meantime.
    ///
    /// The press is dated by the event's own stamp, so arriving a turn later costs it
    /// nothing. [LAW:behavior-not-structure] asserted as what the caller can observe -
    /// a decision in hand with the handler not yet run.
    @Test func theCallbackDecidesBeforeTheHandlerRuns() async throws {
        let tap = FakeTap()
        let hotkey = Hotkey(chords: [rightOption], tap: tap)
        var transitions: [HotkeyDetector.Transition] = []
        try hotkey.start({ transitions.append($0) }, onLapse: { _ in })
        let installation = try #require(tap.installations.first)
        #expect(installation.handle(rightOption(.down, at: 0)) == .swallow)
        #expect(transitions.isEmpty, "the handler ran inside the tap's callback")
        await settle()
        #expect(transitions == [.began(rightOption, at: at(0))])
    }

    /// A tap that can hear only what it asks for is told what the detector looks for.
    @Test func theTapIsToldTheChordsTheDetectorListensFor() throws {
        let tap = FakeTap()
        let chord = Hotkey.defaultChord(for: .release, heardBy: .registeredHotKey)
        try Hotkey(chords: [chord], tap: tap).start({ _ in }, onLapse: { _ in })
        #expect(tap.installations.first?.chords == [chord])
    }

    /// A registered hot key reports the chord going down and coming up as its key moving
    /// under its modifiers, and the detector tells a hold from a tap from those two alone.
    @Test func aChordWithAKeyIsHeldAndTappedFromItsKeyAlone() async throws {
        let chord = Hotkey.defaultChord(for: .release, heardBy: .registeredHotKey)
        let key = try #require(chord.key)
        func moved(_ direction: KeyEvent.Direction, at ms: Int64) -> KeyEvent {
            KeyEvent(key: .key(key), direction: direction, modifiers: chord.modifiers, time: at(ms))
        }
        let tap = FakeTap()
        let hotkey = Hotkey(chords: [chord], tap: tap)
        var transitions: [HotkeyDetector.Transition] = []
        try hotkey.start({ transitions.append($0) }, onLapse: { _ in })
        let installation = try #require(tap.installations.first)
        _ = installation.handle(moved(.down, at: 0))
        _ = installation.handle(moved(.up, at: 400))
        _ = installation.handle(moved(.down, at: 1000))
        _ = installation.handle(moved(.up, at: 1050))
        #expect(hotkey.phase == .latched(chord))
        _ = installation.handle(moved(.down, at: 3000))
        await settle()
        #expect(transitions == [
            .began(chord, at: at(0)), .ended(chord, .released(.hold)),
            .began(chord, at: at(1000)), .ended(chord, .released(.tap)),
        ])
    }

    /// Every lapse is told, as it happens, carrying how many there have been. A lapse
    /// with no press open tells nothing else — no press ended, so no session is reported
    /// — and that is the lapse that swallows the next key-down, so it is the one that
    /// must not pass in silence.
    @Test func everyLapseIsReportedWithItsRunningCount() async throws {
        let tap = FakeTap()
        let hotkey = Hotkey(chords: [rightOption], tap: tap)
        var transitions: [HotkeyDetector.Transition] = []
        var lapses: [KeyboardTapLapse] = []
        try hotkey.start({ transitions.append($0) }, onLapse: { lapses.append($0) })
        #expect(tap.installations[0].onLapse(at(0), .tooSlow) == .rearm)
        #expect(tap.installations[0].onLapse(at(1000), .tooSlow) == .rearm)
        await settle()
        #expect(lapses == [KeyboardTapLapse(count: 1, cause: .tooSlow, response: .rearm), KeyboardTapLapse(count: 2, cause: .tooSlow, response: .rearm)])
        #expect(transitions.isEmpty)
    }

    /// **A tap that keeps lapsing comes down instead of going back on.**
    ///
    /// Every lapse is keys the user typed that nobody received, and switching the tap
    /// back on buys another round of them. Past the cap the tap is costing the session
    /// more than the hotkey returns, and the keyboard is worth more than the hotkey.
    @Test func aTapThatKeepsLapsingComesDown() async throws {
        let tap = FakeTap()
        let hotkey = Hotkey(chords: [rightOption], tap: tap)
        var lapses: [KeyboardTapLapse] = []
        try hotkey.start({ _ in }, onLapse: { lapses.append($0) })
        let installation = try #require(tap.installations.first)
        for index in 1..<Hotkey.lapsesBeforeComingDown {
            #expect(installation.onLapse(at(Int64(index) * 100), .tooSlow) == .rearm)
        }
        #expect(installation.onLapse(at(Int64(Hotkey.lapsesBeforeComingDown) * 100), .tooSlow) == .comeDown)
        await settle()
        #expect(lapses.last == KeyboardTapLapse(count: Hotkey.lapsesBeforeComingDown, cause: .tooSlow, response: .comeDown))
        // Taken down in full, not left as a switched-off tap nobody disposed: a caller
        // offering the user a way to start it again has to be able to tell it is off.
        #expect(!hotkey.isWatching)
        #expect(installation.disposed)
    }

    /// **The tap is down before the come-down is reported.**
    ///
    /// The report invites the user to start the hotkey again, so a handler acting on it
    /// immediately is the contract read plainly. A teardown still waiting its turn behind
    /// that report would dispose the tap the handler just installed and leave the app with
    /// no keyboard at all.
    @Test func aTapStartedFromTheComeDownReportIsNotTornDown() async throws {
        let tap = FakeTap()
        let hotkey = Hotkey(chords: [rightOption], tap: tap)
        try hotkey.start({ _ in }, onLapse: { [weak hotkey] lapse in
            guard case .comeDown = lapse.response, let hotkey else { return }
            try? hotkey.start({ _ in }, onLapse: { _ in })
        })
        let installation = try #require(tap.installations.first)
        for index in 1...Hotkey.lapsesBeforeComingDown {
            _ = installation.onLapse(at(Int64(index) * 100), .tooSlow)
        }
        await settle()
        #expect(tap.installations.count == 2, "the report did not reach a handler able to start again")
        #expect(!tap.installations[1].disposed, "the restarted tap was disposed by a teardown still queued behind the report")
        #expect(hotkey.isWatching)
    }

    /// A lapse the system took around the user's own input is not this app being slow, so
    /// it never counts towards the cap. Counting it would take the hotkey down for
    /// something this app did not do and could go no faster to avoid.
    @Test func lapsesTheUserCausedNeverTakeTheTapDown() async throws {
        let tap = FakeTap()
        let hotkey = Hotkey(chords: [rightOption], tap: tap)
        try hotkey.start({ _ in }, onLapse: { _ in })
        let installation = try #require(tap.installations.first)
        for index in 1...(Hotkey.lapsesBeforeComingDown * 3) {
            #expect(installation.onLapse(at(Int64(index) * 100), .userInput) == .rearm,
                    "lapse \(index) took the tap down for input this app did not cause")
        }
        #expect(hotkey.isWatching)
    }

    /// Lapses far enough apart are separate bad moments rather than a tap that cannot
    /// keep up, so the hotkey survives any number of them.
    @Test func lapsesSpreadWiderThanTheWindowKeepTheTapUp() async throws {
        let tap = FakeTap()
        let hotkey = Hotkey(chords: [rightOption], tap: tap)
        try hotkey.start({ _ in }, onLapse: { _ in })
        let installation = try #require(tap.installations.first)
        let apart = Hotkey.lapseWindow + .milliseconds(1)
        for index in 0..<(Hotkey.lapsesBeforeComingDown * 3) {
            let moment = HostTime(uptime: apart * Double(index))
            #expect(installation.onLapse(moment, .tooSlow) == .rearm, "lapse \(index + 1) took the tap down")
        }
    }

    /// The count belongs to the tap that is up now: a start puts a fresh one in front of
    /// the keyboard, and what the last one lost is not charged to it.
    @Test func aStartCountsFromTheTapItInstalls() async throws {
        let tap = FakeTap()
        let hotkey = Hotkey(chords: [rightOption], tap: tap)
        var lapses: [KeyboardTapLapse] = []
        try hotkey.start({ _ in }, onLapse: { lapses.append($0) })
        _ = tap.installations[0].onLapse(at(0), .tooSlow)
        try hotkey.start({ _ in }, onLapse: { lapses.append($0) })
        _ = tap.installations[1].onLapse(at(1000), .tooSlow)
        await settle()
        #expect(lapses == [KeyboardTapLapse(count: 1, cause: .tooSlow, response: .rearm), KeyboardTapLapse(count: 1, cause: .tooSlow, response: .rearm)])
        #expect(tap.installations[0].disposed)
        #expect(tap.installations.count == 2)
    }

    /// A lapse ends the press that was open, so the handler is not left waiting for
    /// an end the tap never saw, and the next press begins from rest. The handler is
    /// told a lapse ended it, not a release: the tap went deaf and the speaker may
    /// still have been talking into it.
    @Test func aLapseEndsTheOpenPressAtTheHandler() async throws {
        let tap = FakeTap()
        let hotkey = Hotkey(chords: [rightOption], tap: tap)
        var transitions: [HotkeyDetector.Transition] = []
        var lapses: [KeyboardTapLapse] = []
        try hotkey.start({ transitions.append($0) }, onLapse: { lapses.append($0) })
        let installation = try #require(tap.installations.first)
        _ = installation.handle(rightOption(.down, at: 0))
        _ = installation.onLapse(at(500), .tooSlow)
        await settle()
        // Both told: the lapse in its own right, and the press it ended.
        #expect(lapses == [KeyboardTapLapse(count: 1, cause: .tooSlow, response: .rearm)])
        #expect(transitions == [.began(rightOption, at: at(0)), .ended(rightOption, .lapsed)])
        #expect(hotkey.phase == .idle)
        #expect(installation.handle(rightOption(.down, at: 1000)) == .swallow)
        await settle()
        #expect(transitions.last == .began(rightOption, at: at(1000)))
    }

    /// Stopping mid-press ends the press as lapsed at its handler, since its release can
    /// no longer arrive, and a later start begins from rest.
    @Test func stopEndsAnOpenPressAndDisposesTheTap() async throws {
        let tap = FakeTap()
        let hotkey = Hotkey(chords: [rightOption], tap: tap)
        var transitions: [HotkeyDetector.Transition] = []
        try hotkey.start({ transitions.append($0) }, onLapse: { _ in })
        _ = tap.installations[0].handle(rightOption(.down, at: 0))
        hotkey.stop()
        #expect(tap.installations[0].disposed)
        #expect(hotkey.phase == .idle)
        await settle()
        // The ending goes out the same way the beginning did, so it cannot overtake it.
        #expect(transitions == [.began(rightOption, at: at(0)), .ended(rightOption, .lapsed)])
        hotkey.stop()
        await settle()
        #expect(transitions.count == 2)
    }

    @Test func aRefusedTapThrowsFromStart() {
        let hotkey = Hotkey(chords: [rightOption], tap: FakeTap(refusing: Refused()))
        #expect(throws: Refused.self) { try hotkey.start({ _ in }, onLapse: { _ in }) }
        #expect(hotkey.phase == .idle)
    }

    @Test func releasingTheHotkeyDisposesTheTap() throws {
        let tap = FakeTap()
        do {
            let hotkey = Hotkey(chords: [rightOption], tap: tap)
            try hotkey.start({ _ in }, onLapse: { _ in })
        }
        #expect(tap.installations[0].disposed)
    }
}

/// The two facts that stop one installation's keyboard from reaching the other's.
///
/// Driven from `Flavor.allCases` rather than from the two chords spelled out, so a third
/// installation is covered by existing rather than by somebody remembering these.
/// [LAW:behavior-not-structure]
@Suite struct EveryInstallationsChordTests {
    /// The set a typist refuses is every installation's, not the running one's. A
    /// development typist that refused only `{rightOption, rightCommand}` would press a
    /// bare Right Option happily, and the helper's keystrokes are hardware to macOS: the
    /// release app's tap takes it and dictates.
    @Test func everyFlavoursChordIsOneTheTypistRefuses() {
        for flavor in Flavor.allCases {
            for hearing in HotkeySource.allCases {
                #expect(Hotkey.everyInstallationsChord.contains(Hotkey.defaultChord(for: flavor, heardBy: hearing)),
                        "\(flavor)'s \(hearing) chord is not in the set a typist refuses")
            }
        }
    }

    /// The registered hot key's chords are ones the window server can register, and no
    /// two installations' are one hot key to it. None holds Control: the chord is held over
    /// whatever has focus while the person speaks, and Control+D over a terminal is
    /// end-of-file, which closed the shell it was held in.
    @Test func everyRegisteredHotKeyChordIsARegistrableHotKeyOfItsOwn() throws {
        let chords = Set(Flavor.allCases.map { Hotkey.defaultChord(for: $0, heardBy: .registeredHotKey) })
        #expect(chords.count == Flavor.allCases.count)
        for chord in chords {
            #expect(chord.key != nil, "\(chord) has no key")
            #expect(!chord.modifiers.contains(.function), "\(chord) holds function")
            #expect(chord.modifiers.isDisjoint(with: [.leftControl, .rightControl]), "\(chord) holds Control")
        }
    }

    /// The development chord in `held`'s order, spelled out, because this is the order that
    /// once shipped wrong: the menu bar and `dictate` both printed
    /// `hold rightOption+rightCommand to dictate`, and a reader following it literally
    /// completed the release chord first. `Modifier.allCases` puts rightOption at 5 and
    /// rightCommand at 7, so the order came straight from the enum's declaration order -
    /// a fact about how the cases were typed, being read as a fact about the keyboard.
    @Test func theDevelopmentChordIsPrintedInTheOrderThatDoesNotStartTheOtherCopy() {
        #expect(Hotkey.held(Hotkey.defaultChord(for: .development, heardBy: .eventTap)) == "rightCommand+rightOption")
        #expect(Hotkey.held(Hotkey.defaultChord(for: .release, heardBy: .eventTap)) == "rightOption")
    }

    /// **The order printed is an order that works.** A chord completes on whichever
    /// modifier comes down last, so pressing them in an order whose *prefix* is another
    /// installation's whole chord starts a press there instead. `rightOption+rightCommand`
    /// - what the menu and the CLI both printed - is exactly that: Right Option alone is
    /// the release chord, complete.
    ///
    /// This asserts the property rather than the string, so it stays true of chords nobody
    /// has written yet. [LAW:verifiable-goals]
    @Test func theOrderPrintedIsAnOrderThatWorks() {
        // Only a chord of modifiers alone completes as its modifiers go down; a chord with a
        // key waits for the key, so a prefix of modifiers can complete only these.
        let rivals = Hotkey.everyInstallationsChord.filter { $0.key == nil }
        for chord in Hotkey.everyInstallationsChord {
            let order = Hotkey.pressOrder(of: chord)
            #expect(Set(order) == chord.modifiers, "\(chord): the order is not the chord")
            for held in 1..<max(order.count, 1) {
                let prefix = Set(order.prefix(held))
                #expect(!rivals.contains(where: { $0.modifiers == prefix }),
                        "\(chord): holding \(order.prefix(held).map(\.rawValue).joined(separator: "+")) completes another installation's chord first")
            }
        }
    }
}
