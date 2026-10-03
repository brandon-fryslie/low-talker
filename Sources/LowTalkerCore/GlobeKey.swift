import Identity

/// What macOS does when the Globe key (Fn) is pressed on its own: System Settings ›
/// Keyboard › "Press 🌐 key to", stored as `AppleFnUsageType` in `com.apple.HIToolbox`.
///
/// The input method is handed Fn under each of the four: measured on studious, 2026-10-03,
/// with Fn posted as an event, which macOS's own Globe-key handling does not see. A press of
/// the key itself is what that setting acts on, so anything but Do Nothing runs macOS's
/// action beside every press of the chord, and changing the input source takes the person
/// off the input method the chord and the words go through.
public enum GlobeKeyAction: Equatable, Sendable {
    case doNothing
    case changeInputSource
    case showEmojiAndSymbols
    case startDictation
    /// No value stored: macOS does its default, which differs between versions.
    case unset
    /// A value this version does not know.
    case unrecognized(Int)

    /// [LAW:parse-dont-validate] The stored preference, as `CFPreferencesCopyAppValue` hands
    /// it over, or nil when there is none.
    public init(appleFnUsageType value: Int?) {
        self = switch value {
        case nil: .unset
        case 0?: .doNothing
        case 1?: .changeInputSource
        case 2?: .showEmojiAndSymbols
        case 3?: .startDictation
        case let other?: .unrecognized(other)
        }
    }

    /// What the menu says under the hotkey when a chord in `chords` holds Fn and macOS also
    /// acts on it, or nil when nothing does: no chord holds Fn, or the key is set to Do Nothing.
    /// [LAW:no-silent-failure] The person sees macOS's action on every press and is told here
    /// which setting stops it.
    public func clash(with chords: Set<KeyChord>) -> String? {
        let also: String? = switch self {
        case .doNothing: nil
        case .changeInputSource: "changes the input source away from \(AppIdentity.displayName)"
        case .showEmojiAndSymbols: "shows Emoji & Symbols"
        case .startDictation: "starts macOS Dictation"
        case .unset: "does what macOS does with it by default"
        case .unrecognized(let value): "does macOS's action \(value), which this version does not know"
        }
        let holdsFn = chords.contains { $0.modifiers.contains(.function) }
        return (holdsFn ? also : nil).map { "Fn also \($0): in System Settings › Keyboard, set “Press 🌐 key to” to Do Nothing" }
    }
}
