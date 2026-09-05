import AppKit
import LowTalkerCore
import Testing

/// The app the paste is aimed at. What it does when the chord arrives is the test's
/// to say: read the pasteboard like a text field, ignore it, or take the pasteboard.
@MainActor
private final class ReceivingApp: KeyPoster {
    private(set) var pressed: [KeyChord] = []
    private let onChord: @MainActor () -> Void

    init(onChord: @escaping @MainActor () -> Void = {}) {
        self.onChord = onChord
    }

    func post(_ chord: KeyChord) {
        pressed.append(chord)
        onChord()
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
        try prior.write(to: pasteboard)
        var read: String?
        var typesOffered: [NSPasteboard.PasteboardType] = []
        let app = ReceivingApp { [pasteboard] in
            typesOffered = pasteboard.types ?? []
            read = pasteboard.string(forType: .string)
        }
        let inserter = PasteInserter(pasteboard: pasteboard, keys: app)
        let outcome = try await inserter.insert("hello there")
        #expect(outcome == PasteOutcome(landed: true, restored: true))
        #expect(read == "hello there")
        #expect(app.pressed == [PasteInserter.pasteChord])
        #expect(typesOffered.contains(PasteInserter.transientType))
        #expect(PasteboardContents(reading: pasteboard) == prior)
    }

    @Test func anEmptyPasteboardComesBackEmpty() async throws {
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let app = ReceivingApp { [pasteboard] in _ = pasteboard.string(forType: .string) }
        let outcome = try await PasteInserter(pasteboard: pasteboard, keys: app).insert("hello")
        #expect(outcome == PasteOutcome(landed: true, restored: true))
        #expect(PasteboardContents(reading: pasteboard) == PasteboardContents(items: []))
    }

    @Test func aFocusThatNeverPastesGetsThePasteboardBackWhenTheWaitRunsOut() async throws {
        defer { pasteboard.releaseGlobally() }
        let prior = try priorContents()
        try prior.write(to: pasteboard)
        let inserter = PasteInserter(pasteboard: pasteboard, keys: ReceivingApp(), landingTimeout: .milliseconds(20))
        let outcome = try await inserter.insert("hello")
        #expect(outcome == PasteOutcome(landed: false, restored: true))
        #expect(PasteboardContents(reading: pasteboard) == prior)
    }

    /// The second insert waits for the first, so the first still owns the pasteboard
    /// when its wait ends and the prior contents come back once, at the end.
    @Test func overlappingInsertsRunOneAfterAnother() async throws {
        defer { pasteboard.releaseGlobally() }
        let prior = try priorContents()
        try prior.write(to: pasteboard)
        let inserter = PasteInserter(pasteboard: pasteboard, keys: ReceivingApp(), landingTimeout: .milliseconds(30))
        let first = Task { @MainActor in try await inserter.insert("one") }
        let second = Task { @MainActor in try await inserter.insert("two") }
        #expect(try await first.value == PasteOutcome(landed: false, restored: true))
        #expect(try await second.value == PasteOutcome(landed: false, restored: true))
        #expect(PasteboardContents(reading: pasteboard) == prior)
    }

    @Test func aPasteboardTakenDuringThePasteIsLeftWithWhatTookIt() async throws {
        defer { pasteboard.releaseGlobally() }
        try priorContents().write(to: pasteboard)
        let app = ReceivingApp { [pasteboard] in
            pasteboard.clearContents()
            pasteboard.setString("theirs", forType: .string)
        }
        let inserter = PasteInserter(pasteboard: pasteboard, keys: app, landingTimeout: .seconds(5))
        let outcome = try await inserter.insert("hello")
        #expect(outcome == PasteOutcome(landed: false, restored: false))
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
        try contents.write(to: pasteboard)
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

@Suite struct KeystrokeTests {
    private let shiftBits = CGEventFlags(rawValue: 0x2 | 0x4)

    /// Both shifts held: the side-blind Shift bit stays set until the last one is up.
    @Test func aSideBlindBitOutlivesTheFirstOfTwoSidesReleased() {
        let strokes = KeyChord(key: Key(rawValue: 0), modifiers: [.leftShift, .rightShift]).keystrokes
        #expect(strokes.map(\.type) == [.flagsChanged, .flagsChanged, .keyDown, .keyUp, .flagsChanged, .flagsChanged])
        #expect(strokes.map(\.key) == [56, 60, 0, 0, 60, 56])
        #expect(strokes.map(\.flags) == [
            .maskShift.union(CGEventFlags(rawValue: 0x2)),
            .maskShift.union(shiftBits),
            .maskShift.union(shiftBits),
            .maskShift.union(shiftBits),
            .maskShift.union(CGEventFlags(rawValue: 0x2)),
            [],
        ])
    }

    @Test func aModifierOnlyChordHasNoKeyEvents() {
        let strokes = KeyChord(modifiers: .rightOption).keystrokes
        #expect(strokes.map(\.type) == [.flagsChanged, .flagsChanged])
        #expect(strokes.map(\.flags) == [.maskAlternate.union(CGEventFlags(rawValue: 0x40)), []])
    }
}
