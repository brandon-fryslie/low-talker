import KeyboardLayout
import Keystrokes
import LowTalkerCore

/// The app's one inserter: text and chords, lowered to keystrokes and pressed on a
/// keyboard, with every key released again when a run stops.
///
/// Two steps, and the value between them is the proof. `lower` turns text or a chord
/// into keystrokes this typist may press - every character on the layout, every
/// keystroke clear of the hotkey - and refuses the whole of it before a key goes down.
/// `type` and `press` take only what `lower` returned, so nothing half-proven can reach
/// the keyboard, and a caller with several things to type can lower all of them before
/// typing any. [LAW:parse-dont-validate]
///
/// The hotkey is refused here and nowhere else. The virtual keyboard is hardware to
/// macOS, so the app's own event tap sees every key this presses, and a keystroke that
/// holds the hotkey's modifiers would begin a press at the detector: dictation
/// retriggering dictation. Text never reaches it - a layout lowers every character to
/// the left modifiers, and the default hotkey is Right Option - but a chord names its
/// sides and could. The answer is a refusal by type rather than a tap that is asked to
/// look away for a while, because the tap can lapse and be switched back on mid-insert
/// and a typist that had counted on its silence would be surprised. [LAW:single-enforcer]
@MainActor
public struct Typist {
    public let keyboard: any Keyboard
    /// The chords the tap listens for, lowered to what they look like on the wire. A
    /// hotkey holding Fn has no wire form and can never be pressed here, so it refuses
    /// nothing. [LAW:dataflow-not-control-flow]
    private let hotkeys: [Hotkey]

    public init(keyboard: any Keyboard, hotkeys: Set<KeyChord>) {
        self.keyboard = keyboard
        self.hotkeys = hotkeys.compactMap(Hotkey.init)
    }

    /// Text proven typeable: every character has keys on the layout, and no keystroke
    /// would press the hotkey.
    public struct Text {
        fileprivate let characters: [(character: Character, keystrokes: [Keystroke])]
        /// How many characters the keys will put on screen, which is what `type` counts
        /// against.
        public var count: Int { characters.count }
    }

    /// A chord proven pressable and clear of the hotkey.
    public struct Chord {
        fileprivate let keystroke: Keystroke
    }

    /// [LAW:parse-dont-validate] The whole string is refused rather than typed up to the
    /// first character the layout cannot type or the first keystroke that is the hotkey -
    /// half a sentence in a document is worse than none, because only one of the two is
    /// obviously wrong.
    public func lower(_ text: String, on layout: KeyboardLayout) throws -> Text {
        let characters = try layout.typing(text)
        for keystroke in characters.flatMap(\.keystrokes) { try refuse(keystroke) }
        return Text(characters: characters)
    }

    public func lower(_ chord: KeyChord) throws -> Chord {
        let keystroke = try Keystroke(chord: chord)
        try refuse(keystroke)
        return Chord(keystroke: keystroke)
    }

    /// Types the text and answers with how many characters were posted and acknowledged,
    /// which is `text.count` on every return: a run that stops throws `TypingStopped`
    /// with the count instead.
    @discardableResult
    public func type(_ text: Text) throws -> Int {
        var scribe = Scribe(keyboard: keyboard)
        do {
            for (character, keystrokes) in text.characters { try scribe.type(character, keystrokes) }
        } catch {
            throw TypingStopped(typed: scribe.typed, of: text.count, halfTyped: scribe.halfTyped, cause: error, unreleased: release())
        }
        return scribe.typed
    }

    public func press(_ chord: Chord) throws {
        var scribe = Scribe(keyboard: keyboard)
        do {
            try scribe.press(chord.keystroke)
        } catch {
            throw ChordStopped(cause: error, unreleased: release())
        }
    }

    /// Every key up, on the way out of a run that stopped. A run that stopped inside a
    /// keystroke left that keystroke's modifiers held, and macOS repeats a held key into
    /// whatever comes forward next. The release is not guarded by the check, for the
    /// reason `Scribe` gives; what it answers is whether the keys are known to be up.
    /// [LAW:no-silent-failure] A release that fails is reported beside the stop rather
    /// than thrown over it, so the operator is told both.
    private func release() -> (any Error)? {
        do {
            try keyboard.releaseAll()
            return nil
        } catch {
            return error
        }
    }

    private func refuse(_ keystroke: Keystroke) throws {
        if let hotkey = hotkeys.first(where: { $0.isPressed(by: keystroke) }) {
            throw WouldPressTheHotkey(hotkey: hotkey.chord, keystroke: keystroke)
        }
    }

    /// A chord the tap listens for, as the wire would carry it.
    private struct Hotkey {
        let chord: KeyChord
        let modifiers: Modifiers
        let key: Usage?

        init?(_ chord: KeyChord) {
            let usages = chord.modifiers.map(\.usage)
            guard usages.allSatisfy({ $0 != nil }) else { return nil }
            let key: Usage?
            switch chord.key {
            case .none: key = nil
            case .some(let named):
                // A hotkey struck on a key with no usage is as unpressable as one holding Fn.
                guard let usage = Usage(virtualKeyCode: named.rawValue) else { return nil }
                key = usage
            }
            self.chord = chord
            self.modifiers = Modifiers(usages.compactMap { $0 })
            self.key = key
        }

        /// Whether the tap would see this keystroke as the hotkey. The modifiers go down
        /// one at a time, so a keystroke holding the hotkey's modifiers and more presses
        /// the hotkey on its way to the rest; and a hotkey with no key is pressed by any
        /// keystroke that holds its modifiers.
        func isPressed(by keystroke: Keystroke) -> Bool {
            keystroke.modifiers.isSuperset(of: modifiers) && key.map { $0 == keystroke.usage } ?? true
        }
    }
}

/// A keystroke that would press the chord the app listens for. Refused before any key
/// goes down: a typist that pressed it would start a dictation from inside one.
public struct WouldPressTheHotkey: Error, CustomStringConvertible {
    public let hotkey: KeyChord
    public let keystroke: Keystroke

    public var description: String {
        "a keystroke holding \(keystroke.modifiers.usages.count) modifiers over usage 0x\(String(keystroke.usage.rawValue, radix: 16)) would press the hotkey \(hotkey.spelled); nothing was typed"
    }
}

/// A run that stopped once text was already in the target: focus moved, the daemon went
/// quiet, the operator interrupted it. What stopped it is the cause; how much is in the
/// document is the part only this knows, and the part the operator has to act on, since
/// text already typed cannot be taken back.
public struct TypingStopped: Error, CustomStringConvertible {
    public let typed: Int
    public let of: Int
    /// The character whose first keystroke landed and whose last did not, when the run
    /// stopped inside one. It is not in the count, because it is not on screen; it is in
    /// the target app as a pending accent, which is a different thing to act on.
    public let halfTyped: Character?
    public let cause: any Error
    /// The failure of the release that followed the stop, when it failed too. Nil says
    /// every key is up; anything else says one may be held, and macOS will repeat it.
    public let unreleased: (any Error)?

    public init(typed: Int, of: Int, halfTyped: Character? = nil, cause: any Error, unreleased: (any Error)? = nil) {
        self.typed = typed
        self.of = of
        self.halfTyped = halfTyped
        self.cause = cause
        self.unreleased = unreleased
    }

    public var description: String {
        // "Posted and acknowledged", not "typed", and the difference is the spike's whole
        // finding: the daemon acknowledges reports the driver then drops, so the count is
        // what left here and an upper bound on what landed, never a delivery receipt. A
        // run interrupted at 445 has been seen to leave 436 in the document.
        let progress = typed < of
            ? "\(typed) of \(of) characters had been posted and acknowledged before this, and the rest were not sent"
            : "all \(of) characters had been posted and acknowledged before this"
        // A dead key posted without the letter after it leaves the app mid-composition,
        // which no reset here can clear and which silently changes the next character
        // that app receives. [LAW:no-silent-failure]
        let pending = halfTyped.map { ", and \(String($0).debugDescription) was left half typed: its accent is pending in the app and will combine with whatever it receives next" } ?? ""
        return "\(cause). \(progress)\(pending)\(Self.unreleased(unreleased))"
    }

    /// The same sentence a stopped chord ends with. [LAW:one-source-of-truth]
    static func unreleased(_ error: (any Error)?) -> String {
        error.map { ". The keyboard was not released afterwards: \($0). A key may be left held" } ?? ""
    }
}

/// A chord whose press stopped part way. There is no count to carry - a chord is one
/// keystroke - but there is the same question about the keys.
public struct ChordStopped: Error, CustomStringConvertible {
    public let cause: any Error
    public let unreleased: (any Error)?

    public init(cause: any Error, unreleased: (any Error)? = nil) {
        self.cause = cause
        self.unreleased = unreleased
    }

    public var description: String { "\(cause)\(TypingStopped.unreleased(unreleased))" }
}
