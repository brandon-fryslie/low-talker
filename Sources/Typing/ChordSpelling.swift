import Carbon.HIToolbox
import KeyboardLayout
import Keystrokes
import LowTalkerCore

public extension KeyChord {
    /// A chord as a script writes it: modifier names and one key, joined by `+` -
    /// `leftCommand+s`, `leftShift+leftCommand+left`, `return`.
    ///
    /// A modifier is named the way the config file names one, by `Modifier`'s own words. The
    /// key has three spellings, and each reaches keys the others cannot:
    /// - a name, for the keys a shell cannot hand over as a character: `return`, `escape`,
    ///   `left`, `f5`, and the rest of `namedKeys`;
    /// - the character the layout types with that key and nothing held, `s` or `/`. Read
    ///   off `layout`, because which key a letter is on is the layout's to say: `s` is key
    ///   code 1 on US and 41 on Dvorak, and a chord is the key;
    /// - `key 0x24`, the spelling `Hotkey.held` gives every key, so any chord this program
    ///   prints can be handed back to it. [LAW:one-source-of-truth]
    ///
    /// [LAW:parse-dont-validate] Only the spelling is proven here. Whether the device can
    /// press the chord is `Keystroke(chord:)`'s to say and whether it would press a hotkey is
    /// `Typist`'s, so a chord of modifiers alone parses, and is refused where a decoded one
    /// is. [LAW:single-enforcer]
    init(spelled spelling: String, on layout: KeyboardLayout) throws(ChordSpellingError) {
        var modifiers: Set<Modifier> = []
        var keys: [Key] = []
        for term in spelling.split(separator: "+", omittingEmptySubsequences: false).map(String.init) {
            if let modifier = Modifier(rawValue: term) {
                modifiers.insert(modifier)
            } else {
                keys.append(try Self.key(spelled: term, in: spelling, on: layout))
            }
        }
        guard keys.count <= 1 else { throw .moreThanOneKey(spelling) }
        // Every term is a modifier or a key and an empty term is refused as neither, so
        // there is always at least one of them by here.
        self.init(modifiers: modifiers, key: keys.first)!
    }

    /// The keys named by a word, from Carbon's own key code constants. Only keys that type
    /// no character a shell can pass as an argument are here; a key that types one is
    /// spelled by that character, on the layout.
    static let namedKeys: [String: Key] = {
        let named: [String: Int] = [
            "return": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, "delete": kVK_Delete,
            "forwardDelete": kVK_ForwardDelete, "escape": kVK_Escape, "help": kVK_Help,
            "home": kVK_Home, "end": kVK_End, "pageUp": kVK_PageUp, "pageDown": kVK_PageDown,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
        ]
        let functionRow = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                           kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        let functionKeys = Dictionary(uniqueKeysWithValues: functionRow.enumerated().map { ("f\($0.offset + 1)", $0.element) })
        return named.merging(functionKeys) { named, _ in named }.mapValues { Key(rawValue: UInt16($0)) }
    }()

    /// The one key a term that is not a modifier names, by whichever of the three spellings
    /// it is written in.
    private static func key(spelled term: String, in spelling: String, on layout: KeyboardLayout) throws(ChordSpellingError) -> Key {
        if let named = namedKeys[term] { return named }
        if term.hasPrefix(heldPrefix), let code = UInt16(term.dropFirst(heldPrefix.count), radix: 16) {
            return Key(rawValue: code)
        }
        guard term.count == 1 else { throw .unknownTerm(term, in: spelling) }
        let typing: [(character: Character, keystrokes: [Keystroke])]
        do { typing = try layout.typing(term) } catch { throw .notOneKey(term, layout: layout.name) }
        // One character, one keystroke, nothing held: a character reached through Shift or
        // a dead key is not a key of its own, and the modifiers are the chord's to name.
        guard let keystroke = typing.first?.keystrokes.first, typing.first?.keystrokes.count == 1, keystroke.modifiers.isEmpty,
              let code = keystroke.usage.virtualKeyCode else {
            throw .notOneKey(term, layout: layout.name)
        }
        return Key(rawValue: code)
    }

    /// How `Hotkey.held` begins a key it names by code.
    private static let heldPrefix = "key 0x"
}

/// A chord spelling that names no chord, and why.
public enum ChordSpellingError: Error, CustomStringConvertible, Equatable {
    /// A term that is no modifier, no key name, no key code and no single character - an
    /// empty one between two `+` included.
    case unknownTerm(String, in: String)
    /// A character the layout does not type with one key and nothing held.
    case notOneKey(String, layout: String)
    case moreThanOneKey(String)

    public var description: String {
        switch self {
        case .unknownTerm(let term, let spelling):
            "\(term.debugDescription) in \(spelling.debugDescription) is not a modifier (\(Modifier.allCases.map(\.rawValue).joined(separator: ", "))), a key name (\(KeyChord.namedKeys.keys.sorted().joined(separator: ", "))), a key code written key 0x24, or a single character"
        case .notOneKey(let character, let layout):
            "\(layout) does not type \(character.debugDescription) with one key and nothing held; name the key it is on, and the modifiers as modifiers"
        case .moreThanOneKey(let spelling):
            "\(spelling.debugDescription) names more than one key; a chord is modifiers and one key, and several chords are several arguments"
        }
    }
}
