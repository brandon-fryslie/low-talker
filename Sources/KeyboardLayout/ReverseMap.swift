import Carbon.HIToolbox
import Keystrokes

extension KeyboardLayout {
    /// The modifier combinations a character can be typed with, in the order a person
    /// reaches for them. The order is the preference: when two ways type the same
    /// character, the plainer one is what this keeps, so `a` is the A key and not some
    /// option-sequence that happens to produce the same letter.
    ///
    /// Command is not here. It does not change what a key types - it changes what the key
    /// means - and a layout asked about it answers with the unmodified character, which
    /// would fill the map with duplicates that type shortcuts instead of text.
    private static var combinations: [(state: UInt32, modifiers: Modifiers)] {
        [
            (0, []),
            (UInt32(shiftKey >> 8), .leftShift),
            (UInt32(optionKey >> 8), .leftOption),
            (UInt32((shiftKey | optionKey) >> 8), [.leftShift, .leftOption]),
        ]
    }

    /// Every character this layout can type, and what it costs.
    ///
    /// One walk, breadth-first, because a dead key types nothing by itself. Each entry is
    /// a sequence of keystrokes already pressed and the composition it left pending; the
    /// walk asks every key what it types after that sequence, records the characters, and
    /// pushes back any key that answered with a pending composition of its own. A layout
    /// whose dead keys chain is followed the whole way rather than one key in, and it is
    /// not a case bolted on for that: it is the same loop every un-composed key goes
    /// through, entered with the empty sequence. [LAW:parse-dont-validate]
    ///
    /// Nothing installed on this Mac chains. ABC Extended is the deepest layout here - 26
    /// pending compositions, more than a thousand characters - and every one of them is
    /// reached one key past a dead key. The walk is written this way because it is less
    /// code than the two passes it replaces, not for a layout that was measured and found.
    ///
    /// Breadth-first is the preference order, not an implementation detail. Shorter
    /// sequences are expanded first, so the first sequence to reach a character is the
    /// cheapest one, and nothing after it overwrites: `a` stays the A key rather than some
    /// dead-key sequence that composes to the same letter.
    ///
    /// The walk terminates on the states, not on a depth limit. A layout has finitely many
    /// pending compositions and each is expanded once, so a layout whose dead keys cycle
    /// is walked out rather than followed forever. [LAW:no-silent-failure]
    static func reverseMap(of layout: UnsafePointer<UCKeyboardLayout>) -> [Character: [Keystroke]] {
        var map: [Character: [Keystroke]] = [:]
        var pending: [(pressed: [Keystroke], state: UInt32)] = [([], 0)]
        var walked: Set<UInt32> = [0]
        let keyboardType = UInt32(LMGetKbdType())

        var next = 0
        while next < pending.count {
            let sequence = pending[next]
            next += 1
            for (keystroke, code, state) in everyKey {
                var deadKeyState = sequence.state
                let typed = translate(layout, code, state, keyboardType, &deadKeyState)
                if typed.isEmpty {
                    guard deadKeyState != 0, walked.insert(deadKeyState).inserted else { continue }
                    pending.append((sequence.pressed + [keystroke], deadKeyState))
                } else if let character = one(typed), map[character] == nil {
                    map[character] = sequence.pressed + [keystroke]
                }
            }
        }

        // Return types a carriage return, and text says newline. They are the same key and
        // the same intent, and a document that took every character except its line breaks
        // would be the kind of near-miss that reads as working.
        map["\n"] = [Keystroke(.returnKey)]
        return map
    }

    /// Every key this can press, with the modifiers held, in preference order.
    private static var everyKey: [(keystroke: Keystroke, code: UInt16, state: UInt32)] {
        (UInt16(0)..<128).flatMap { code in
            guard let usage = Usage(virtualKeyCode: code) else { return [(Keystroke, UInt16, UInt32)]() }
            return combinations.map { (Keystroke(usage, $0.modifiers), code, $0.state) }
        }
    }

    /// What one key with one set of modifiers types, given whatever accent is pending.
    ///
    /// `deadKeyState` goes in and comes back out: zero in and non-zero out is how a dead
    /// key announces itself, and passing a non-zero state in is how the key after one is
    /// asked what the pair composes to.
    private static func translate(
        _ layout: UnsafePointer<UCKeyboardLayout>,
        _ code: UInt16,
        _ modifierState: UInt32,
        _ keyboardType: UInt32,
        _ deadKeyState: inout UInt32
    ) -> String {
        var characters = [UniChar](repeating: 0, count: 8)
        var length = 0
        let status = UCKeyTranslate(
            layout, code, UInt16(kUCKeyActionDown), modifierState, keyboardType,
            0, &deadKeyState, characters.count, &length, &characters
        )
        guard status == noErr else { return "" }
        return String(utf16CodeUnits: characters, count: length)
    }

    /// One character, or nothing.
    ///
    /// A key can answer with more than one - a dead key followed by a letter it does not
    /// accent gives the accent and the letter both - and that is a pair of characters no
    /// single keystroke types, so it is not a row in a map from one character to its keys.
    /// Counted as Swift counts characters, so `é` written as e plus a combining accent is
    /// the one character it reads as. [LAW:types-are-the-program]
    private static func one(_ typed: String) -> Character? {
        typed.count == 1 ? typed.first : nil
    }
}
