import CoreGraphics
import Dispatch
import Flavors
import Insertion
import os

/// The hotkey heard through this installation's input method: the input method tells the
/// app every change of the modifier keys it is handed, and this turns each change into the
/// key events that make it, for the detector above to find presses in exactly as it does for
/// the event tap. Nothing is granted to the app for it.
///
/// [LAW:composability] It sits behind the same seam as the other taps, so hold, tap and a
/// latched press behave the same whichever hears them. What it cannot do is why it is not
/// the only tap: the input method is handed keys only by an app in front that takes typing,
/// and by none under Secure Event Input, so a press anywhere else never arrives. It never
/// swallows anything, since the input method hands every key back, and it never lapses.
///
/// A release is the one change it cannot wait to be told. One made where the input method
/// is handed nothing, or told while the app's port was full, would leave the microphone open
/// until the next change happened to arrive; so while anything is held, the app reads the
/// session's modifier keys itself - a reading that needs no grant - and lets go of what is no
/// longer down. [LAW:no-silent-failure]
public struct InputMethodModifiers: KeyboardTap {
    private let flavor: Flavor

    public init(flavor: Flavor) {
        self.flavor = flavor
    }

    /// How often a held key is looked for in the session: how late, at most, a release the
    /// input method never told is heard.
    static let confirming: DispatchTimeInterval = .milliseconds(200)

    /// What the port's messages reach on the main actor: while the tap is open, the port and
    /// the handler; and the modifiers the detector has been told are held.
    ///
    /// The port and the handler go together, because a message can still be on its way to
    /// the main queue when the tap is disposed of, and a hotkey that has stopped must hear
    /// nothing after it: the event tap's callbacks cannot arrive late, and these can.
    /// Disposing of the tap is what closes the port, then and there, and what a late message
    /// finds. [LAW:no-ambient-temporal-coupling]
    @MainActor
    private final class Installed {
        var open: (port: ModifierPort, handle: @MainActor (KeyEvent) -> HotkeyDetector.Passage)? {
            didSet { settleConfirming() }
        }
        private var told: ToldModifiers
        private var confirming: DispatchSourceTimer?

        init(told: ToldModifiers) {
            self.told = told
        }

        func heard(_ moves: [KeyEvent]) {
            // The passage is the event tap's question. The input method hands every key
            // back whatever the answer, so there is nothing here to keep back.
            open.map { open in moves.forEach { _ = open.handle($0) } }
            settleConfirming()
        }

        func heard(_ state: HeldModifiers) {
            heard(told.take(Modifier.held(in: CGEventFlags(rawValue: state.flags)),
                            at: HostTime(uptime: .nanoseconds(state.uptimeNanoseconds))))
        }

        /// [LAW:dataflow-not-control-flow] The session is read for as long as the tap is
        /// open and something is held, derived from those two facts wherever either changes,
        /// so there is no starting or stopping of it to get out of step with them.
        private func settleConfirming() {
            switch (open != nil && !told.held.isEmpty, confirming) {
            case (true, nil):
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.schedule(deadline: .now() + InputMethodModifiers.confirming, repeating: InputMethodModifiers.confirming,
                               leeway: .milliseconds(50))
                timer.setEventHandler { [unowned self] in
                    MainActor.assumeIsolated {
                        heard(told.confirm(session: Modifier.held(in: CGEventSource.flagsState(.combinedSessionState)), at: .now))
                    }
                }
                timer.resume()
                confirming = timer
            case (false, let timer?):
                timer.cancel()
                confirming = nil
            case (true, _?), (false, nil):
                break
            }
        }
    }

    /// `onLapse` is never called: there is no tap for the system to switch off, and no
    /// stream of other keys to fall behind on.
    ///
    /// Throws when the hotkey port cannot be hosted - most often because another process of
    /// this installation already hears on it, such as `lowtalker hotkey` run beside the app.
    public func install(
        listeningFor _: Set<KeyChord>,
        handling handle: @escaping @MainActor (KeyEvent) -> HotkeyDetector.Passage,
        onLapse _: @escaping @MainActor (HostTime, LapseCause) -> LapseResponse
    ) throws -> Disposal {
        // What is held as listening begins is read, not assumed to be nothing, so a key
        // already down when this comes up is not heard going down when it next moves.
        let installed = Installed(told: ToldModifiers(held: Modifier.held(in: CGEventSource.flagsState(.combinedSessionState))))
        let log = Logger(subsystem: flavor.bundleIdentifier, category: "hotkey")
        // Checked and read off the main thread, where the keys and the menu are, and handed
        // to it in the order the input method sent them: the main queue is first in, first
        // out, which keeps a key's down ahead of its up. [LAW:no-ambient-temporal-coupling]
        let port = try ModifierPort(
            flavor: flavor, queue: DispatchQueue(label: flavor.hotkeyPortName),
            told: { event in log.error("\(event.description, privacy: .public)") },
            heard: { state in DispatchQueue.main.async { MainActor.assumeIsolated { installed.heard(state) } } })
        installed.open = (port, handle)
        // Closed here and now, so a hotkey rebuilt straight after hosts the name again.
        return { installed.open = nil }
    }
}

/// The modifier keys the detector has been told are held: what each state heard next is the
/// difference from.
///
/// Two readings reach it. The input method's, which can press and let go, stamped when its
/// event happened and arriving in that order; and the app's own of the session, which only
/// confirms what is still down and so can only let go. What the session let go of is kept
/// per key with when it was read, because a message from the input method stamped before
/// then can still be on its way holding that key, and must not press it again - while
/// every other key in that message is news the session read could not have given, and is
/// taken. [LAW:no-ambient-temporal-coupling]
public struct ToldModifiers: Sendable {
    public private(set) var held: Set<Modifier>
    private var letGo: [Modifier: HostTime] = [:]

    public init(held: Set<Modifier>) {
        self.held = held
    }

    /// The key events that take the detector to holding `now`, as the input method read it
    /// at `time`.
    public mutating func take(_ now: Set<Modifier>, at time: HostTime) -> [KeyEvent] {
        // A later message has nothing older left to be overtaken by. [LAW:dataflow-not-control-flow]
        letGo = letGo.filter { $0.value > time }
        return move(to: now.subtracting(letGo.keys), at: time)
    }

    /// The key events that let go of what `session`, read at `time`, no longer holds.
    public mutating func confirm(session: Set<Modifier>, at time: HostTime) -> [KeyEvent] {
        held.subtracting(session).forEach { letGo[$0] = time }
        return move(to: held.intersection(session), at: time)
    }

    private mutating func move(to now: Set<Modifier>, at time: HostTime) -> [KeyEvent] {
        defer { held = now }
        return KeyEvent.moves(from: held, to: now, at: time)
    }
}

extension KeyEvent {
    /// The key events that take the keyboard from holding `before` to holding `after`, each
    /// carrying what is held once it has happened: what a stream of states becomes for the
    /// detector, which reads keys moving.
    ///
    /// A state that did not change is no events at all, which is what makes a state told
    /// twice - VS Code hands the input method each change twice, measured on studious,
    /// 2026-09-27 - the same as one. A state that moved by several keys at once, because
    /// the input method was not handed the changes in between or read the state after the
    /// next had already come, is every one of them, the keys that came up first.
    ///
    /// The keys that went down are pressed in `Hotkey.pressOrder`, which puts a key another
    /// installation's chord contains last: two keys that went down together are then never
    /// taken for a chord of the other installation's that only one of them completes.
    /// [LAW:one-source-of-truth]
    public static func moves(from before: Set<Modifier>, to after: Set<Modifier>, at time: HostTime) -> [KeyEvent] {
        let released = Modifier.allCases.filter { before.contains($0) && !after.contains($0) }
        let pressed = KeyChord(modifiers: after.subtracting(before), key: nil).map(Hotkey.pressOrder(of:)) ?? []
        var held = before
        let ups = released.map { modifier in
            held.remove(modifier)
            return KeyEvent(key: .modifier(modifier), direction: .up, modifiers: held, time: time)
        }
        let downs = pressed.map { modifier in
            held.insert(modifier)
            return KeyEvent(key: .modifier(modifier), direction: .down, modifiers: held, time: time)
        }
        return ups + downs
    }
}
