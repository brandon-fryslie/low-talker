import KeyboardLayout
import Keystrokes
import LowTalkerCore

public extension Hotkey {
    /// An installation's chord in the words a person presses it by.
    ///
    /// The event tap hears sides, so its chord is `held`, sides and order included. A
    /// registered hot key does not: Carbon matches Control, Option, Shift and Command
    /// whichever side is down, so naming a side would tell the reader something false. Its
    /// key is named by the layout the user types on, because the chord is a physical key
    /// and the letter printed on it is the layout's to say - key code 2 is D on US and E
    /// on Dvorak. [LAW:one-source-of-truth] The name is read off the layout's own map, not
    /// a table kept beside it.
    @MainActor
    static func named(_ chord: KeyChord, heardBy delivery: Delivery, on layout: KeyboardLayout) -> String {
        switch delivery {
        case .virtualKeyboard:
            return held(chord)
        case .inputMethod:
            let sides: [(name: String, either: Set<Modifier>)] = [
                ("Control", [.leftControl, .rightControl]), ("Option", [.leftOption, .rightOption]),
                ("Shift", [.leftShift, .rightShift]), ("Command", [.leftCommand, .rightCommand]),
            ]
            let modifiers = sides.filter { !chord.modifiers.isDisjoint(with: $0.either) }.map(\.name)
            let key = chord.key.map { name(of: $0, on: layout) }
            return (modifiers + (key.map { [$0] } ?? [])).joined(separator: "+")
        }
    }

    /// A key as the layout prints it. A key whose character is not one a person reads - an
    /// arrow or a function key, which layouts answer with a control or private-use code -
    /// keeps the spelling `held` gives every key, which says which key it is if not its name.
    private static func name(of key: Key, on layout: KeyboardLayout) -> String {
        let typed: Character? = Usage(virtualKeyCode: key.rawValue).flatMap { layout.character(typedBy: Keystroke($0)) }
        guard let typed, typed.isLetter || typed.isNumber || typed.isPunctuation || typed.isSymbol else {
            return "key 0x" + String(key.rawValue, radix: 16)
        }
        return String(typed).uppercased()
    }
}
