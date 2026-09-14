/// How the words a user dictates reach them, which is also how the hotkey is heard.
///
/// [LAW:no-mode-explosion] One choice and not two flags. What a method costs to install is
/// the sum of what its hotkey and its output need, and the only reason to pick
/// `clipboard` is that it needs nothing an administrator has to approve - so a
/// clipboard output behind an event tap, which needs Input Monitoring, is a combination
/// nobody would choose, and it is not one this type can say.
public enum InputMethod: String, CaseIterable, Sendable, CustomStringConvertible {
    /// The hotkey is a registered hot key and the words go on the clipboard for the user
    /// to paste. Nothing is installed and nothing asks for an administrator.
    case clipboard
    /// The hotkey is an event tap and the words are typed on the virtual keyboard, through
    /// the driver extension and the root helper.
    case virtualKeyboard

    /// The spelling a stored choice is kept under, which is the case name.
    public var description: String { rawValue }
}
