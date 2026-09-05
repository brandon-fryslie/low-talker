import AppKit

/// Everything a pasteboard held at one moment: each item with every type it carried,
/// in the order it carried them, and the bytes behind each, so the same items can be
/// put back later.
///
/// [LAW:effects-at-boundaries] The two ways in and out of a pasteboard are here, and
/// the value in between is plain data a test can compare.
public struct PasteboardContents: Hashable, Sendable {
    /// One type an item carries and the bytes behind it.
    public struct Representation: Hashable, Sendable {
        public let type: NSPasteboard.PasteboardType
        public let data: Data

        public init(type: NSPasteboard.PasteboardType, data: Data) {
            self.type = type
            self.data = data
        }
    }

    /// An item's representations in the order its owner declared them, which readers
    /// take as the owner's preference.
    public typealias Item = [Representation]

    public let items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    /// Reads every item now. A type whose owner promised data and cannot deliver it
    /// (a stale promise, a file promise) has nothing to put back and is not kept.
    public init(reading pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { Representation(type: type, data: $0) }
            }
        }
    }

    /// Replaces the pasteboard's contents with these items.
    public func write(to pasteboard: NSPasteboard) throws {
        pasteboard.clearContents()
        // [LAW:no-silent-failure] AppKit reports a refused write with a Bool; the
        // caller learns the prior contents did not come back.
        guard pasteboard.writeObjects(items.map(NSPasteboardItem.init)) else { throw PasteboardError.writeRefused }
    }
}

extension NSPasteboardItem {
    convenience init(_ item: PasteboardContents.Item) {
        self.init()
        for representation in item {
            setData(representation.data, forType: representation.type)
        }
    }
}

public enum PasteboardError: Error, CustomStringConvertible {
    case writeRefused

    public var description: String {
        switch self {
        case .writeRefused: "the pasteboard refused a write"
        }
    }
}
