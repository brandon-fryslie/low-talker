import Carbon.HIToolbox
import Foundation
import Keystrokes

/// What it costs to type a character on one keyboard layout: the keys, and the modifiers
/// held while they are pressed.
///
/// The map runs backwards from the way the OS thinks. macOS answers "what does this key
/// with these modifiers type"; typing needs the reverse, and the reverse is not a table
/// Apple publishes - it is built by asking the forward question about every key and every
/// modifier combination and keeping the answers. How many questions that is depends on how
/// many dead keys the layout has, which is the layout's business; all of them are asked
/// once, when it is read. [LAW:no-ambient-temporal-coupling]
///
/// A layout is a value here, not a global. `current()` is the one impure step - it asks
/// the system which layout is in front - and everything after it is a pure function of the
/// bytes that came back. [LAW:effects-at-boundaries] That is also what lets a test type
/// through Dvorak without switching the machine's keyboard out from under the user.
public struct KeyboardLayout: Sendable {
    /// The keystrokes for each character: one for most, and as many as the layout takes
    /// for a character reached through dead keys.
    private let byCharacter: [Character: [Keystroke]]
    /// What the layout calls itself, for a failure that has to name it.
    public let name: String

    /// Text Input Sources aborts the process - not an error, `abort()` - when two threads
    /// are inside it at once, so every call this module makes into it goes through one
    /// lock. [LAW:single-enforcer] A caller cannot be asked to remember a rule whose
    /// penalty is that the process is gone before it can be told.
    ///
    /// This covers only this module's own calls. In a process that also drives AppKit,
    /// AppKit calls the same API from the main thread, and Apple's rule there is that
    /// everyone does: read layouts on the main actor in the app.
    private static let textInputSources = NSLock()

    /// The layout the OS would type with right now - for *this* process's user.
    ///
    /// Not the console user's, when the two differ. A process running as root is answered
    /// with root's own layout, measured on this Mac: with the machine switched to Dvorak,
    /// the console user is told Dvorak and `sudo` is told US, and typing the US keys under
    /// Dvorak puts "yd. 'gcjt" on screen for "the quick". So the layout is read where the
    /// user is, and the keystrokes travel to whatever privileged thing owns the device -
    /// which is why text becomes keystrokes on the client side of that seam and not past
    /// it. [LAW:one-way-deps]
    public static func current() throws -> KeyboardLayout {
        try textInputSources.withLock {
            guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
                throw NoLayout.noCurrentSource
            }
            return try KeyboardLayout(source: source)
        }
    }

    /// One input source, by the id Apple gives it - `com.apple.keylayout.Dvorak` and the
    /// like. Present so a layout other than the machine's own can be read without
    /// selecting it, which is how the Dvorak case is tested and how a future setting would
    /// name a layout.
    public static func named(_ identifier: String) throws -> KeyboardLayout {
        try textInputSources.withLock {
            let query = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
            let sources = TISCreateInputSourceList(query, true)?.takeRetainedValue() as? [TISInputSource]
            guard let source = sources?.first else { throw NoLayout.noSourceNamed(identifier) }
            return try KeyboardLayout(source: source)
        }
    }

    /// Private because it reads input source properties, which is the API above: the two
    /// entry points hold the lock across this and there is no third way in.
    private init(source: TISInputSource) throws {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            // A source with no uchr data is one of the input methods - Pinyin, Kotoeri -
            // rather than a keyboard layout. There is no key that types a character
            // through it, so there is nothing this could return. [LAW:no-silent-failure]
            throw NoLayout.noKeyLayoutData(Self.name(of: source))
        }
        // The bytes as CoreFoundation laid them out, not a Data copy of them: a copy is
        // aligned for bytes and `UCKeyboardLayout` is not a byte, so binding a copy's
        // memory to it traps. The source owns this data and outlives the map built from it.
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { throw NoLayout.noKeyLayoutData(Self.name(of: source)) }
        name = Self.name(of: source)
        byCharacter = Self.reverseMap(of: UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self))
    }

    private static func name(of source: TISInputSource) -> String {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "an unnamed layout" }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    /// What it takes to type `text`, character by character.
    ///
    /// Grouped rather than flat because a character is not always a keystroke: `\u{e9}` on a US
    /// layout is option-e and then e, so a caller counting keystrokes and reporting
    /// characters would over-report how much of the text reached the screen, which is the
    /// one number an operator has to act on when a run stops part way.
    ///
    /// [LAW:parse-dont-validate] A character this layout cannot type is refused here, with
    /// every such character named, and the string is refused whole rather than typed up to
    /// the first one - half a sentence in a document is worse than none, because only one
    /// of the two is obviously wrong.
    public func typing(_ text: String) throws -> [(character: Character, keystrokes: [Keystroke])] {
        // Composed first. The map is keyed by what Swift calls a character - a grapheme
        // cluster - and filled with what the keys type, which is the composed form; text
        // that arrives decomposed is the same string to Swift and a different key to a
        // dictionary, so `e` followed by a combining acute would be refused as untypeable
        // while `\u{e9}` types. Canonically equivalent strings compare equal in Swift, so
        // this changes what is typed for nobody and a caller reading the screen back
        // against its own text still matches. [LAW:parse-dont-validate]
        // Line breaks next, and for the same reason one step further on: Return is one
        // key, and a document that receives it holds one line break however the text asked
        // for it. A CRLF is a single grapheme cluster to Swift and a lone CR is what the
        // layout itself answers with, and both come back from the screen as a newline - so
        // a caller comparing what it asked for against what it reads would find a mismatch
        // in a run that typed perfectly. Normalised here, the characters returned below are
        // what the keys put on screen. [LAW:parse-dont-validate]
        let text = text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let untypeable = text.filter { byCharacter[$0] == nil }
        guard untypeable.isEmpty else {
            throw UntypeableCharacters(characters: String(Set(untypeable).sorted()), layout: name)
        }
        return text.map { ($0, byCharacter[$0]!) }
    }

    /// The same keystrokes in one run, for a caller that types the whole string or none.
    public func keystrokes(for text: String) throws -> [Keystroke] {
        try typing(text).flatMap(\.keystrokes)
    }

    /// Whether this layout can type every character of `text`, without building anything.
    public func canType(_ text: String) -> Bool {
        text.precomposedStringWithCanonicalMapping.allSatisfy { byCharacter[$0] != nil }
    }
}

/// A character the layout has no keys for. Emoji and every script the layout does not
/// carry land here by design: this types a keyboard, and a keyboard has the keys it has.
public struct UntypeableCharacters: Error, CustomStringConvertible, Equatable {
    public let characters: String
    public let layout: String
    public var description: String {
        "\(layout) has no keys for \(characters)"
    }
}

public enum NoLayout: Error, CustomStringConvertible, Equatable {
    case noCurrentSource
    case noSourceNamed(String)
    case noKeyLayoutData(String)

    public var description: String {
        switch self {
        case .noCurrentSource: "the system reported no current keyboard layout"
        case .noSourceNamed(let id): "no keyboard layout is installed with the id \(id)"
        case .noKeyLayoutData(let name): "\(name) is an input method rather than a keyboard layout, so no key types a character through it"
        }
    }
}
