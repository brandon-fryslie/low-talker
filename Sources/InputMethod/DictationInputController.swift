import AppKit
import InputMethodKit

/// The controller macOS offers every key to while this input method is the selected source,
/// which declines every one of them.
///
/// An input method sits between the keyboard and whatever the person is typing into, so the
/// keys it does not hand back are keys that never arrive anywhere. Declining all of them is
/// what makes selecting this source cost nothing: the app in front sees exactly the keys it
/// would have seen under the person's own layout, dead keys and shortcuts included, because
/// the text input system delivers them itself once the controller says it did not.
///
/// [LAW:dataflow-not-control-flow] There is no key this looks at and no state it keeps, so
/// there is no input for which it behaves differently - the answer is a constant, not a
/// decision. What low-input-method-s71.31s adds is insertion the *app* asks for, which
/// arrives by a different door entirely; a key claimed here would be a broken keyboard, and
/// the swallowed key is invisible - the person sees a letter that did not appear.
/// [LAW:no-silent-failure]
///
/// `@objc` with an explicit name because `InputMethodServerControllerClass` in the bundle's
/// `Info.plist` names this class as a string, and the Objective-C runtime is what resolves
/// it; `InputMethodPlistTests` holds that string to this name.
@objc(DictationInputController)
public final class DictationInputController: IMKInputController {
    /// Every event, declined. The signature is `IMKInputController`'s; returning false is
    /// how it says "not mine", which is the whole behaviour of this ticket's controller.
    override public func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        false
    }
}
