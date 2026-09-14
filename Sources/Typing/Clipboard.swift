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
    private let pasteboard: NSPasteboard

    public init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    /// The one every app pastes from.
    public static var general: Clipboard { Clipboard(.general) }

    func write(_ text: String) throws {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw ClipboardRefused(pasteboard: pasteboard.name.rawValue) }
    }
}

/// The pasteboard server would not take the words. [LAW:no-silent-failure]
public struct ClipboardRefused: Error, CustomStringConvertible {
    public let pasteboard: String

    public var description: String { "the pasteboard \(pasteboard) refused the dictated text; nothing was copied" }
}
