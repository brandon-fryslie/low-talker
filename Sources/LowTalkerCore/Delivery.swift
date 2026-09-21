/// How the words a user dictates reach them, which is also how the hotkey is heard.
///
/// Named for the delivery and not for the input method, because macOS has an input
/// method of its own - a text input source, the way Pinyin or Kotoeri is one - and this
/// program will grow one. Two meanings under one word in one menu and one log would
/// mislead every later reader. [LAW:one-source-of-truth]
///
/// [LAW:no-mode-explosion] One choice and not two flags. What a delivery costs to install
/// is the sum of what its hotkey and its output need, and the only reason to pick
/// `clipboard` is that it needs nothing an administrator has to approve - so a
/// clipboard output behind an event tap, which needs Input Monitoring, is a combination
/// nobody would choose, and it is not one this type can say.
public enum Delivery: String, CaseIterable, Sendable, CustomStringConvertible {
    /// The hotkey is a registered hot key and the words go on the clipboard for the user
    /// to paste. Nothing is installed and nothing asks for an administrator.
    case clipboard
    /// The hotkey is an event tap and the words are typed on the virtual keyboard, through
    /// the driver extension and the root helper.
    case virtualKeyboard

    /// The spelling a stored choice is kept under, which is the case name.
    public var description: String { rawValue }
}
