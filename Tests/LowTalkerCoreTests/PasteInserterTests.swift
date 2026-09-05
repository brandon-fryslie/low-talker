import AppKit
import LowTalkerCore
import Testing

/// The app the paste is aimed at. What it does when asked to paste is the test's to
/// say: read the pasteboard like a text field, refuse, or take the pasteboard.
@MainActor
private final class ReceivingApp: PasteReceiver {
    private(set) var pastes = 0
    private let onPaste: @MainActor () async throws -> Void

    init(onPaste: @escaping @MainActor () async throws -> Void = {}) {
        self.onPaste = onPaste
    }

    func paste() async throws {
        pastes += 1
        try await onPaste()
    }
}

private let custom = NSPasteboard.PasteboardType("com.example.low-talker.test")

private func onePixelPNG() throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32))
    bitmap.setColor(.red, atX: 0, y: 0)
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

/// An image item carrying two representations, then a text item with a private type
/// beside the string: the shape a copy from a real app leaves.
private func priorContents() throws -> PasteboardContents {
    let png = try onePixelPNG()
    return PasteboardContents(items: [
        [.init(type: .png, data: png), .init(type: .tiff, data: try #require(NSImage(data: png)?.tiffRepresentation))],
        [.init(type: .string, data: Data("kept".utf8)), .init(type: custom, data: Data([1, 2, 3]))],
    ])
}

@MainActor
@Suite struct PasteInserterTests {
    private let pasteboard = NSPasteboard.withUniqueName()

    @Test func theTextLandsAndThePriorItemsComeBackIncludingTheImage() async throws {
        defer { pasteboard.releaseGlobally() }
        let prior = try priorContents()
        prior.write(to: pasteboard)
        var read: String?
        var typesOffered: [NSPasteboard.PasteboardType] = []
        let app = ReceivingApp { [pasteboard] in
            typesOffered = pasteboard.types ?? []
            read = pasteboard.string(forType: .string)
        }
        let outcome = try await PasteInserter(pasteboard: pasteboard).insert("hello there", into: app)
        #expect(outcome == .restored)
        #expect(read == "hello there")
        #expect(app.pastes == 1)
        #expect(typesOffered.contains(PasteInserter.transientType))
        #expect(PasteboardContents(reading: pasteboard) == prior)
    }

    @Test func anEmptyPasteboardComesBackEmpty() async throws {
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let app = ReceivingApp { [pasteboard] in _ = pasteboard.string(forType: .string) }
        let outcome = try await PasteInserter(pasteboard: pasteboard).insert("hello", into: app)
        #expect(outcome == .restored)
        #expect(PasteboardContents(reading: pasteboard) == PasteboardContents(items: []))
    }

    @Test func anAppThatCannotPasteStillGetsThePasteboardBack() async throws {
        defer { pasteboard.releaseGlobally() }
        let prior = try priorContents()
        prior.write(to: pasteboard)
        let app = ReceivingApp { throw PasteError.noPasteMenuItem(bundleID: "com.example.menuless") }
        let failed = try await #require(throws: InsertionFailed.self) {
            try await PasteInserter(pasteboard: pasteboard).insert("hello", into: app)
        }
        #expect(failed.reason as? PasteError == .noPasteMenuItem(bundleID: "com.example.menuless"))
        #expect(failed.pasteboard == .restored)
        #expect(PasteboardContents(reading: pasteboard) == prior)
    }

    @Test func aFailedPasteSaysWhenThePasteboardWasTakenMeanwhile() async throws {
        defer { pasteboard.releaseGlobally() }
        try priorContents().write(to: pasteboard)
        let app = ReceivingApp { [pasteboard] in
            pasteboard.clearContents()
            pasteboard.setString("theirs", forType: .string)
            throw PasteError.unanswered(.cannotComplete)
        }
        let failed = try await #require(throws: InsertionFailed.self) {
            try await PasteInserter(pasteboard: pasteboard).insert("hello", into: app)
        }
        #expect(failed.pasteboard == .pasteboardTaken)
        #expect(pasteboard.string(forType: .string) == "theirs")
    }

    /// The second insert waits for the first, so each paste reads its own text and the
    /// prior contents come back once, at the end. The first app holds its paste open
    /// until the test lets go, and the second insert is submitted only once it is in.
    @Test func overlappingInsertsRunOneAfterAnother() async throws {
        defer { pasteboard.releaseGlobally() }
        let prior = try priorContents()
        prior.write(to: pasteboard)
        var read: [String?] = []
        let (entered, enteredFirst) = AsyncStream.makeStream(of: Void.self)
        var letGo: CheckedContinuation<Void, Never>?
        let app = ReceivingApp { [pasteboard] in
            read.append(pasteboard.string(forType: .string))
            guard letGo == nil else { return }
            await withCheckedContinuation { letGo = $0; enteredFirst.yield() }
        }
        let inserter = PasteInserter(pasteboard: pasteboard)
        let first = Task { @MainActor in try await inserter.insert("one", into: app) }
        for await _ in entered { break }
        let second = Task { @MainActor in try await inserter.insert("two", into: app) }
        for _ in 0..<10 { await Task.yield() }
        #expect(read == ["one"])
        letGo?.resume()
        #expect(try await first.value == .restored)
        #expect(try await second.value == .restored)
        #expect(read == ["one", "two"])
        #expect(PasteboardContents(reading: pasteboard) == prior)
    }

    @Test func aPasteboardTakenDuringThePasteIsLeftWithWhatTookIt() async throws {
        defer { pasteboard.releaseGlobally() }
        try priorContents().write(to: pasteboard)
        let app = ReceivingApp { [pasteboard] in
            pasteboard.clearContents()
            pasteboard.setString("theirs", forType: .string)
        }
        let outcome = try await PasteInserter(pasteboard: pasteboard).insert("hello", into: app)
        #expect(outcome == .pasteboardTaken)
        #expect(pasteboard.string(forType: .string) == "theirs")
    }
}

/// An owner that promised data and never delivers: what a stale or file promise
/// looks like to a reader.
private final class EmptyPromise: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {}
}

@MainActor
@Suite struct PasteboardContentsTests {
    @Test func writingThenReadingGivesBackEveryItemAndType() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let contents = try priorContents()
        contents.write(to: pasteboard)
        #expect(PasteboardContents(reading: pasteboard) == contents)
        #expect(pasteboard.pasteboardItems?.count == 2)
    }

    @Test func anItemWhosePromiseNeverDeliversIsNotKept() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let promised = NSPasteboardItem()
        promised.setDataProvider(EmptyPromise(), forTypes: [.string])
        let kept = NSPasteboardItem()
        kept.setString("kept", forType: .string)
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([promised, kept]))
        #expect(PasteboardContents(reading: pasteboard) == PasteboardContents(items: [[.init(type: .string, data: Data("kept".utf8))]]))
    }
}
