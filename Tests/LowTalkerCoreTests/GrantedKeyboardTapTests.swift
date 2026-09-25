import LowTalkerCore
import Testing

/// The hotkey's event tap: never created without its grants, and a refusal despite them
/// said as the relaunch it most likely needs. [LAW:behavior-not-structure]
@MainActor
@Suite struct GrantedKeyboardTapTests {
    /// The tap underneath, which records whether it was asked for and answers as a test says.
    private final class Underneath: KeyboardTap {
        private(set) var installs = 0
        private let refusal: KeyboardTapError?

        init(refusing refusal: KeyboardTapError? = nil) { self.refusal = refusal }

        func install(
            listeningFor chords: Set<KeyChord>,
            handling handle: @escaping @MainActor (KeyEvent) -> HotkeyDetector.Passage,
            onLapse: @escaping @MainActor (HostTime, LapseCause) -> LapseResponse
        ) throws -> Disposal {
            installs += 1
            if let refusal { throw refusal }
            return {}
        }
    }

    private static func install(_ tap: GrantedKeyboardTap) throws {
        _ = try tap.install(listeningFor: [], handling: { _ in .pass }, onLapse: { _, _ in .comeDown })
    }

    /// Without both grants no tap is asked for at all: asking is what would make macOS
    /// raise its own dialog, unasked.
    @Test func withoutItsGrantsNoTapIsAskedFor() {
        let underneath = Underneath()
        #expect(throws: KeyboardTapError.notAllowed) {
            try Self.install(GrantedKeyboardTap(underneath, granted: { false }))
        }
        #expect(underneath.installs == 0)
    }

    /// Grants that could not be read are not grants withheld: the reading's own error
    /// comes out, and no tap is asked for.
    @Test func anUnreadableGrantIsItsOwnError() {
        struct Unreadable: Error {}
        let underneath = Underneath()
        #expect(throws: Unreadable.self) {
            try Self.install(GrantedKeyboardTap(underneath, granted: { throw Unreadable() }))
        }
        #expect(underneath.installs == 0)
    }

    /// With both grants the tap is made as it always was.
    @Test func withItsGrantsTheTapIsMade() throws {
        let underneath = Underneath()
        try Self.install(GrantedKeyboardTap(underneath, granted: { true }))
        #expect(underneath.installs == 1)
    }

    /// Refused although both grants read as held: said as the restart a grant given while
    /// the process ran needs, never as a grant to give again.
    @Test func aRefusalDespiteTheGrantsIsSaidAsARelaunch() {
        #expect(throws: KeyboardTapError.refusedWhileAllowed) {
            try Self.install(GrantedKeyboardTap(Underneath(refusing: .refused), granted: { true }))
        }
    }
}
