import Choices
import Flavors

/// A mode's chord as each hotkey source hears it: one chord per source, every one of them a
/// chord that source can hear.
///
/// [LAW:types-are-the-program] The sources differ in what they can hear. A registered hot key
/// needs a key and cannot tell left from right; the input method is told only of the
/// modifier keys; an event tap hears anything. So no one chord can stand for all three, and a
/// mode names one per source. The initializer asks for every source's chord and refuses one
/// that source cannot hear, so a HeardChords in hand has a chord that can be heard, whichever
/// source the installation chose.
public struct HeardChords: Hashable, Sendable {
    private let chords: [HotkeySource: KeyChord]

    public init(_ chord: (HotkeySource) -> KeyChord) throws(UnhearableChord) {
        var chords: [HotkeySource: KeyChord] = [:]
        for source in HotkeySource.allCases {
            chords[source] = try source.hearable(chord(source))
        }
        self.chords = chords
    }

    /// The chord `source` listens for. Every source has one, because `init` asks each of
    /// them for it.
    public subscript(source: HotkeySource) -> KeyChord { chords[source]! }

    /// This installation's own chords, which is what a mode the file gives no chord listens
    /// for. The force-try says the author vouches for them: a default no source can hear is
    /// a bug in `Hotkey.defaultChord`, and it traps where it is written.
    public static func `default`(for flavor: Flavor) -> HeardChords {
        try! HeardChords { Hotkey.defaultChord(for: flavor, heardBy: $0) }
    }
}

/// A chord given to a source that cannot hear it, and why.
public struct UnhearableChord: Error, Equatable, Sendable, CustomStringConvertible {
    public let source: HotkeySource
    public let why: String

    public var description: String { why }
}

extension HotkeySource {
    /// `chord`, when this source can hear it.
    ///
    /// [LAW:single-enforcer] The registered hot key's refusal is `RegisteredHotKeys`' own, so
    /// a config refuses exactly what registering it would.
    func hearable(_ chord: KeyChord) throws(UnhearableChord) -> KeyChord {
        switch self {
        case .eventTap:
            break
        case .registeredHotKey:
            do { try RegisteredHotKeys.registrable(chord) } catch { throw UnhearableChord(source: self, why: error.description) }
        case .inputMethod:
            // The input method is told only when a modifier key moves, so a chord with any
            // other key in it would never complete.
            guard chord.key == nil else {
                throw UnhearableChord(source: self, why: "\(chord) has a key besides its modifiers, and the input method hears the modifier keys alone")
            }
        }
        return chord
    }
}
