import AppKit
import InputMethodKit

/// The controller macOS offers the modifier keys to while this input method is the selected
/// source, which declines every one of them.
///
/// An input method sits between the keyboard and whatever the person is typing into, so the
/// keys it does not hand back are keys that never arrive anywhere. Declining all of them is
/// what makes selecting this source cost nothing: the app in front sees exactly the keys it
/// would have seen under the person's own layout, dead keys and shortcuts included, because
/// the text input system delivers them itself once the controller says it did not.
///
/// [LAW:dataflow-not-control-flow] There is no key this looks at, and the cursor it records
/// for `FocusedClient` is never consulted to answer one, so there is no key for which the
/// answer differs - it is a constant, not a decision. What low-input-method-s71.31s adds is insertion the *app* asks for, which
/// arrives by a different door entirely; a key claimed here would be a broken keyboard, and
/// the swallowed key is invisible - the person sees a letter that did not appear.
/// [LAW:no-silent-failure]
///
/// `@objc` with an explicit name because `InputMethodServerControllerClass` in the bundle's
/// `Info.plist` names this class as a string, and the Objective-C runtime is what resolves
/// it; `InputMethodPlistTests` holds that string to this name.
@objc(DictationInputController)
public final class DictationInputController: IMKInputController {
    /// The events this controller is handed: changes of the modifier keys, and nothing
    /// typed. What the text input system offers when nobody says is key-downs alone (0x400,
    /// read off `super` on studious, 2026-09-27), which is every key typed and no modifier
    /// ever moving. Asking for these instead is what lets the app hear a chord of modifiers
    /// alone with no grant, and it means the keys a person types never reach this process.
    override public func recognizedEvents(_: Any!) -> Int {
        Int(NSEvent.EventTypeMask.flagsChanged.rawValue)
    }

    /// Every event, declined, and each one told to `ModifierChanges` as a change of the
    /// modifier keys: `recognizedEvents` asks for nothing else. The signature is
    /// `IMKInputController`'s; returning false is how it says "not mine", which is the whole
    /// behaviour this controller has toward keys - low-input-method-s71.31s added insertion
    /// through a door of the app's, and low-hotkey-aws.yvl the telling, and neither changed
    /// the answer.
    ///
    /// Told whatever the event, rather than after asking which kind it is: what is told is
    /// the state of the modifier keys read off the session, so an event that changed none of
    /// them tells the app nothing it does not already hold. [LAW:dataflow-not-control-flow]
    ///
    /// IMK sometimes calls this with no event at all (seen on this Mac, 2026-09-29, on the
    /// call after an activate), so the event is optional and such a call is told at the
    /// moment it was made, on the clock `NSEvent.timestamp` uses. Unwrapped implicitly, as
    /// the inherited signature has it, that call trapped and took the input method down,
    /// and with it every press until macOS happened to launch it again.
    /// [LAW:types-are-the-program]
    override public func handle(_ event: NSEvent?, client sender: Any!) -> Bool {
        ModifierChanges.shared.moved(at: event?.timestamp ?? ProcessInfo.processInfo.systemUptime)
        return false
    }

    /// The text input system gave this controller's client focus, which is the only way
    /// this process learns where words can go.
    ///
    /// Reported rather than kept, because the client that is in front is not this
    /// controller's to know: `IMKServer` builds one controller per client, and the app's
    /// insert arrives on a port that belongs to none of them. [LAW:one-source-of-truth]
    ///
    /// Focus, not a key: nothing here waits for the person to type, so an insert asked for
    /// before any key has ever arrived is answered like any other. Reported now rather than
    /// hopped onto the main actor for the same reason - a hop would report focus after the
    /// insert that asked about it had already been refused, and the words would be lost
    /// while the cursor sat waiting. [LAW:no-ambient-temporal-coupling]
    override public func activateServer(_ sender: Any!) {
        // The controller is a main-thread object arriving through a signature written
        // before the language could say so, and `assumeIsolated` is where that is asserted
        // and checked. The client is read here and nowhere else on this thread; its commits
        // are made off it, by `Committer`, which is why `Client` is Sendable.
        nonisolated(unsafe) let client = sender as? IMKTextInput
        nonisolated(unsafe) let controller = self
        MainActor.assumeIsolated {
            // A sender no cursor can be made of - no client at all, or a client that will
            // not name its app - changes nothing here. Not reported, because a sender THIS
            // controller cannot understand is no reason to take the cursor away from another
            // controller that can; and not forgotten either, because the cursor last
            // reported is the one `deactivateServer` hands back, so dropping it would leave
            // `FocusedClient` holding a client nobody can retract. One rule, and it lives in
            // `Client.init`: a cursor that exists is a cursor `took` accepts.
            // [LAW:single-enforcer]
            let arriving = client.flatMap(Client.init)
            controller.cursor = arriving ?? controller.cursor
            arriving.map(FocusedClient.shared.took)
        }
    }

    /// Focus left this controller's client.
    ///
    /// The cursor made on the way in is the one handed back, so `FocusedClient` can tell
    /// this client leaving from a different one arriving - a fresh wrapper around the same
    /// client would be a different object and the comparison would always miss.
    override public func deactivateServer(_: Any!) {
        nonisolated(unsafe) let controller = self
        MainActor.assumeIsolated {
            controller.cursor.map(FocusedClient.shared.left)
            controller.cursor = nil
        }
    }

    /// This controller's client, as the one thing this process asks of it.
    ///
    /// Held here because `IMKServer` builds one controller per client, so this IS the one
    /// place with a client's lifetime to hang it on. [LAW:one-source-of-truth] Touched only
    /// inside the assumptions above, which is where its isolation is asserted.
    private nonisolated(unsafe) var cursor: Client?
}
