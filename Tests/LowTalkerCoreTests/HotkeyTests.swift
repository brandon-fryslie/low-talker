import LowTalkerCore
import Testing

private struct Refused: Error, Equatable {}

/// A tap a test controls: the handler it was given is the test's to feed, and the
/// system switching it off is the test's to say.
@MainActor
private final class FakeTap: KeyboardTap {
    final class Installation {
        let handle: @MainActor (KeyEvent) -> HotkeyDetector.Delivery
        let onLapse: @MainActor () -> Void
        var disposed = false

        init(handle: @escaping @MainActor (KeyEvent) -> HotkeyDetector.Delivery, onLapse: @escaping @MainActor () -> Void) {
            self.handle = handle
            self.onLapse = onLapse
        }
    }

    private(set) var installations: [Installation] = []
    private let refusal: (any Error)?

    init(refusing refusal: (any Error)? = nil) {
        self.refusal = refusal
    }

    func install(handling handle: @escaping @MainActor (KeyEvent) -> HotkeyDetector.Delivery, onLapse: @escaping @MainActor () -> Void) throws -> Disposal {
        if let refusal { throw refusal }
        let installation = Installation(handle: handle, onLapse: onLapse)
        installations.append(installation)
        return { installation.disposed = true }
    }
}

private let rightOption = KeyChord(modifiers: .rightOption)

private func at(_ ms: Int64) -> HostTime { HostTime(uptime: .milliseconds(ms)) }

private func rightOption(_ direction: KeyEvent.Direction, at ms: Int64) -> KeyEvent {
    KeyEvent(key: .modifier(.rightOption), direction: direction, modifiers: direction == .down ? [.rightOption] : [], time: at(ms))
}

@MainActor
@Suite struct HotkeyTests {
    @Test func aPressReachesTheHandlerFromInsideTheTapAndIsSwallowed() throws {
        let tap = FakeTap()
        let hotkey = Hotkey(chords: [rightOption], tap: tap)
        var transitions: [HotkeyDetector.Transition] = []
        try hotkey.start({ transitions.append($0) }, onLapse: { _ in })
        let installation = try #require(tap.installations.first)
        #expect(installation.handle(rightOption(.down, at: 0)) == .swallow)
        #expect(transitions == [.began(rightOption, at: at(0))])
        #expect(hotkey.phase == .held(rightOption, since: at(0)))
        #expect(installation.handle(rightOption(.up, at: 400)) == .swallow)
        #expect(transitions == [.began(rightOption, at: at(0)), .ended(rightOption, .released(.hold))])
    }

    /// Every lapse is told, as it happens, carrying how many there have been. A lapse
    /// with no press open tells nothing else — no press ended, so no session is reported
    /// — and that is the lapse that swallows the next key-down, so it is the one that
    /// must not pass in silence.
    @Test func everyLapseIsReportedWithItsRunningCount() throws {
        let tap = FakeTap()
        let hotkey = Hotkey(chords: [rightOption], tap: tap)
        var transitions: [HotkeyDetector.Transition] = []
        var lapses: [KeyboardTapLapse] = []
        try hotkey.start({ transitions.append($0) }, onLapse: { lapses.append($0) })
        tap.installations[0].onLapse()
        tap.installations[0].onLapse()
        #expect(lapses == [KeyboardTapLapse(count: 1), KeyboardTapLapse(count: 2)])
        #expect(transitions.isEmpty)
    }

    /// The count belongs to the tap that is up now: a start puts a fresh one in front of
    /// the keyboard, and what the last one lost is not charged to it.
    @Test func aStartCountsFromTheTapItInstalls() throws {
        let tap = FakeTap()
        let hotkey = Hotkey(chords: [rightOption], tap: tap)
        var lapses: [KeyboardTapLapse] = []
        try hotkey.start({ _ in }, onLapse: { lapses.append($0) })
        tap.installations[0].onLapse()
        try hotkey.start({ _ in }, onLapse: { lapses.append($0) })
        tap.installations[1].onLapse()
        #expect(lapses == [KeyboardTapLapse(count: 1), KeyboardTapLapse(count: 1)])
        #expect(tap.installations[0].disposed)
        #expect(tap.installations.count == 2)
    }

    /// A lapse ends the press that was open, so the handler is not left waiting for
    /// an end the tap never saw, and the next press begins from rest. The handler is
    /// told a lapse ended it, not a release: the tap went deaf and the speaker may
    /// still have been talking into it.
    @Test func aLapseEndsTheOpenPressAtTheHandler() throws {
        let tap = FakeTap()
        let hotkey = Hotkey(chords: [rightOption], tap: tap)
        var transitions: [HotkeyDetector.Transition] = []
        var lapses: [KeyboardTapLapse] = []
        try hotkey.start({ transitions.append($0) }, onLapse: { lapses.append($0) })
        let installation = try #require(tap.installations.first)
        _ = installation.handle(rightOption(.down, at: 0))
        installation.onLapse()
        // Both told: the lapse in its own right, and the press it ended.
        #expect(lapses == [KeyboardTapLapse(count: 1)])
        #expect(transitions == [.began(rightOption, at: at(0)), .ended(rightOption, .lapsed)])
        #expect(hotkey.phase == .idle)
        #expect(installation.handle(rightOption(.down, at: 1000)) == .swallow)
        #expect(transitions.last == .began(rightOption, at: at(1000)))
    }

    /// Stopping mid-press forgets the press: a later start begins from rest.
    @Test func stopDisposesTheTapAndReturnsToIdle() throws {
        let tap = FakeTap()
        let hotkey = Hotkey(chords: [rightOption], tap: tap)
        try hotkey.start({ _ in }, onLapse: { _ in })
        _ = tap.installations[0].handle(rightOption(.down, at: 0))
        hotkey.stop()
        #expect(tap.installations[0].disposed)
        #expect(hotkey.phase == .idle)
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
