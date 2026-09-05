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

private func rightOption(_ direction: KeyEvent.Direction, at ms: Int64) -> KeyEvent {
    KeyEvent(key: .modifier(.rightOption), direction: direction, modifiers: direction == .down ? [.rightOption] : [], time: .milliseconds(ms))
}

@MainActor
@Suite struct HotkeyTests {
    @Test func aPressReachesTheHandlerFromInsideTheTapAndIsSwallowed() throws {
        let tap = FakeTap()
        let hotkey = Hotkey(chords: [rightOption], tap: tap)
        var transitions: [HotkeyDetector.Transition] = []
        try hotkey.start { transitions.append($0) }
        let installation = try #require(tap.installations.first)
        #expect(installation.handle(rightOption(.down, at: 0)) == .swallow)
        #expect(transitions == [.began(rightOption)])
        #expect(hotkey.phase == .held(rightOption, since: .zero))
        #expect(installation.handle(rightOption(.up, at: 400)) == .swallow)
        #expect(transitions == [.began(rightOption), .ended(rightOption, .hold)])
    }

    @Test func aLapseIsCountedAndAStartResetsIt() throws {
        let tap = FakeTap()
        let hotkey = Hotkey(chords: [rightOption], tap: tap)
        try hotkey.start { _ in }
        tap.installations[0].onLapse()
        tap.installations[0].onLapse()
        #expect(hotkey.lapses == 2)
        try hotkey.start { _ in }
        #expect(hotkey.lapses == 0)
        #expect(tap.installations[0].disposed)
        #expect(tap.installations.count == 2)
    }

    /// Stopping mid-press forgets the press: a later start begins from rest.
    @Test func stopDisposesTheTapAndReturnsToIdle() throws {
        let tap = FakeTap()
        let hotkey = Hotkey(chords: [rightOption], tap: tap)
        try hotkey.start { _ in }
        _ = tap.installations[0].handle(rightOption(.down, at: 0))
        hotkey.stop()
        #expect(tap.installations[0].disposed)
        #expect(hotkey.phase == .idle)
    }

    @Test func aRefusedTapThrowsFromStart() {
        let hotkey = Hotkey(chords: [rightOption], tap: FakeTap(refusing: Refused()))
        #expect(throws: Refused.self) { try hotkey.start { _ in } }
        #expect(hotkey.phase == .idle)
    }

    @Test func releasingTheHotkeyDisposesTheTap() throws {
        let tap = FakeTap()
        do {
            let hotkey = Hotkey(chords: [rightOption], tap: tap)
            try hotkey.start { _ in }
        }
        #expect(tap.installations[0].disposed)
    }
}
