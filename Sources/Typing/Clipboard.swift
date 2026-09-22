import AppKit

/// A pasteboard as the place dictated words are left for the user to paste.
///
/// The words replace what was there and stay: the paste is the user's, at a moment
/// nothing here can see, so there is no point after it at which the old contents could be
/// put back.
///
/// [LAW:effects-at-boundaries] Taken as a value, so a test writes to a pasteboard of its
/// own and reads the words back, and the person at the Mac keeps their clipboard.
@MainActor
public struct Clipboard {
    /// The write itself, held as a value rather than a pasteboard to reach for. Every real
    /// one is the closure below; what this buys is the other arm - `NSPasteboard` takes
    /// whatever a test hands it, so a pasteboard that refuses is not a thing a test can
    /// make, and the refusal path had no way to be exercised at all.
    /// [LAW:effects-at-boundaries]
    private let put: (String) throws -> Void

    public init(_ pasteboard: NSPasteboard) {
        put = { text in
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else { throw ClipboardRefused(pasteboard: pasteboard.name.rawValue) }
        }
    }

    init(writing put: @escaping (String) throws -> Void) {
        self.put = put
    }

    /// The one every app pastes from.
    public static var general: Clipboard { Clipboard(.general) }

    func write(_ text: String) throws {
        try put(text)
    }
}

/// The pasteboard server would not take the words. [LAW:no-silent-failure]
public struct ClipboardRefused: Error, CustomStringConvertible {
    public let pasteboard: String

    public var description: String { "the pasteboard \(pasteboard) refused the dictated text; nothing was copied" }
}
