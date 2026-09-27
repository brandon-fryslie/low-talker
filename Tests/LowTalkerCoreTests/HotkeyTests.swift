import Dispatch
import Flavors
import Foundation
import LowTalkerCore
import Testing

private struct Refused: Error, Equatable {}

/// A feed a test controls: the handler it was given is the test's to call.
@MainActor
private final class FakeFeed: ModifierFeed {
    final class Installation {
        let handle: @MainActor (KeyEvent) -> Void
        var disposed = false

        init(handle: @escaping @MainActor (KeyEvent) -> Void) {
            self.handle = handle
        }
    }

    private(set) var installations: [Installation] = []
    private let refusal: (any Error)?

    init(refusing refusal: (any Error)? = nil) {
        self.refusal = refusal
    }

    func install(handling handle: @escaping @MainActor (KeyEvent) -> Void) throws -> Disposal {
        if let refusal { throw refusal }
        let installation = Installation(handle: handle)
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
    KeyEvent(key: .rightOption, direction: direction, modifiers: direction == .down ? [.rightOption] : [], time: at(ms))
}

@MainActor
@Suite struct HotkeyTests {
    @Test func aPressReachesTheHandler() async throws {
        let feed = FakeFeed()
        let hotkey = Hotkey(chords: [rightOption], feed: feed)
        var transitions: [HotkeyDetector.Transition] = []
        try hotkey.start { transitions.append($0) }
        let installation = try #require(feed.installations.first)
        installation.handle(rightOption(.down, at: 0))
        #expect(hotkey.phase == .held(rightOption, since: at(0)))
        await settle()
        #expect(transitions == [.began(rightOption, at: at(0))])
        installation.handle(rightOption(.up, at: 400))
        await settle()
        #expect(transitions == [.began(rightOption, at: at(0)), .ended(rightOption, .released(.hold))])
    }

    /// Every transition leaves by the main queue, never from inside the feed's call, so a
    /// `began` is always ahead of the `ended` that follows it however the two were told.
    /// [LAW:behavior-not-structure] asserted as what the caller can observe - a decision in
    /// hand with the handler not yet run.
    @Test func theHandlerRunsAfterTheEventIsRead() async throws {
        let feed = FakeFeed()
        let hotkey = Hotkey(chords: [rightOption], feed: feed)
        var transitions: [HotkeyDetector.Transition] = []
        try hotkey.start { transitions.append($0) }
        let installation = try #require(feed.installations.first)
        installation.handle(rightOption(.down, at: 0))
        #expect(transitions.isEmpty, "the handler ran inside the feed's call")
        await settle()
        #expect(transitions == [.began(rightOption, at: at(0))])
    }

    /// Stopping mid-press ends the press as lapsed at its handler, since its release can
    /// no longer arrive, and a later start begins from rest.
    @Test func stopEndsAnOpenPressAndDisposesTheFeed() async throws {
        let feed = FakeFeed()
        let hotkey = Hotkey(chords: [rightOption], feed: feed)
        var transitions: [HotkeyDetector.Transition] = []
        try hotkey.start { transitions.append($0) }
        feed.installations[0].handle(rightOption(.down, at: 0))
        hotkey.stop()
        #expect(feed.installations[0].disposed)
        #expect(!hotkey.isWatching)
        #expect(hotkey.phase == .idle)
        await settle()
        // The ending goes out the same way the beginning did, so it cannot overtake it.
        #expect(transitions == [.began(rightOption, at: at(0)), .ended(rightOption, .lapsed)])
        hotkey.stop()
        await settle()
        #expect(transitions.count == 2)
    }

    /// A start puts a fresh feed up and takes the last one down.
    @Test func aStartReplacesTheFeedThatWasUp() throws {
        let feed = FakeFeed()
        let hotkey = Hotkey(chords: [rightOption], feed: feed)
        try hotkey.start { _ in }
        try hotkey.start { _ in }
        #expect(feed.installations.count == 2)
        #expect(feed.installations[0].disposed)
        #expect(!feed.installations[1].disposed)
        #expect(hotkey.isWatching)
    }

    @Test func aRefusedFeedThrowsFromStart() {
        let hotkey = Hotkey(chords: [rightOption], feed: FakeFeed(refusing: Refused()))
        #expect(throws: Refused.self) { try hotkey.start { _ in } }
        #expect(!hotkey.isWatching)
        #expect(hotkey.phase == .idle)
    }

    @Test func releasingTheHotkeyDisposesTheFeed() throws {
        let feed = FakeFeed()
        do {
            let hotkey = Hotkey(chords: [rightOption], feed: feed)
            try hotkey.start { _ in }
        }
        #expect(feed.installations[0].disposed)
    }
}

/// The facts that stop one installation's chord from starting the other's.
///
/// Driven from `Flavor.allCases` rather than from the two chords spelled out, so a third
/// installation is covered by existing rather than by somebody remembering these.
/// [LAW:behavior-not-structure]
@Suite struct EveryInstallationsChordTests {
    @Test func everyFlavoursChordIsInTheSet() {
        let every = Config.everyInstallationsChord { flavor throws(ConfigError) in .noFile(at: URL(filePath: "/nonexistent"), flavor: flavor) }
        for flavor in Flavor.allCases {
            #expect(every.contains(Hotkey.defaultChord(for: flavor)), "\(flavor)'s chord is not in the set")
        }
    }

    /// A chord an installation's file names is the chord it listens for, so it is in the set.
    @Test func aChordAConfigNamesIsInTheSet() throws {
        let edited = try Config(toml: """
            [[modes]]
            name = "dictation"
            chord = { modifiers = ["leftControl"] }
            """, flavor: .release)
        let every = Config.everyInstallationsChord { flavor throws(ConfigError) in
            flavor == .release ? .file(edited, at: URL(filePath: "/tmp/config.toml"), flavor: flavor) : .noFile(at: URL(filePath: "/nonexistent"), flavor: flavor)
        }
        #expect(every.contains(KeyChord(modifiers: .leftControl)))
    }

    /// A file that cannot be read stands as its installation's defaults: that copy comes
    /// up on nothing until it can read it, and on its defaults once the file is gone.
    @Test func anUnreadableFileStandsAsItsInstallationsDefaults() {
        let every = Config.everyInstallationsChord { flavor throws(ConfigError) in throw .noModes }
        for flavor in Flavor.allCases {
            #expect(every.isSuperset(of: Config.default(for: flavor).chords))
        }
    }

    /// The development chord in `held`'s order, spelled out, because this is the order that
    /// once shipped wrong: the menu bar printed `hold rightOption+rightCommand to dictate`,
    /// and a reader following it literally completed the release chord first.
    /// `Modifier.allCases` puts rightOption at 5 and rightCommand at 7, so the order came
    /// straight from the enum's declaration order - a fact about how the cases were typed,
    /// being read as a fact about the keyboard.
    @Test func theDevelopmentChordIsPrintedInTheOrderThatDoesNotStartTheOtherCopy() {
        #expect(Hotkey.held(Hotkey.defaultChord(for: .development)) == "rightCommand+rightOption")
        #expect(Hotkey.held(Hotkey.defaultChord(for: .release)) == "rightOption")
    }

    /// The same chords in a person's words, in the same order.
    @Test func aChordIsNamedInWordsInPressOrder() {
        #expect(Hotkey.named(Hotkey.defaultChord(for: .development)) == "Right Command+Right Option")
        #expect(Hotkey.named(Hotkey.defaultChord(for: .release)) == "Right Option")
    }

    /// **The order printed is an order that works.** A chord completes on whichever
    /// modifier comes down last, so pressing them in an order whose *prefix* is another
    /// installation's whole chord starts a press there instead. `rightOption+rightCommand`
    /// is exactly that: Right Option alone is the release chord, complete.
    ///
    /// This asserts the property rather than the string, so it stays true of chords nobody
    /// has written yet. [LAW:verifiable-goals]
    @Test func theOrderPrintedIsAnOrderThatWorks() {
        let rivals = Hotkey.everyInstallationsChord
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
