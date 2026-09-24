/// How the words a user dictates reach them. How the hotkey is heard is a separate choice,
/// `HotkeySource`, and either goes with either.
///
/// Named for the delivery and not for the input method, because "input method" is what
/// macOS calls a text input source, the way Pinyin or Kotoeri is one, and this program's
/// own is one of those: `inputMethod` is the delivery that goes through it. Two meanings
/// under one word in one menu and one log would mislead every later reader.
/// [LAW:one-source-of-truth]
public enum Delivery: String, CaseIterable, Sendable, CustomStringConvertible {
    /// The words are committed at the cursor by this app's own macOS input method, through
    /// the text input system. Nothing asks for an administrator.
    case inputMethod
    /// The words are typed on the virtual keyboard, through the driver extension and the
    /// root helper.
    case virtualKeyboard

    /// The spelling a stored choice is kept under, which is the case name.
    public var description: String { rawValue }
}
