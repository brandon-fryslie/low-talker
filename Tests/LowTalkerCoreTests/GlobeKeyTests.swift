import LowTalkerCore
import Testing

/// A chord holding Fn is told which setting stops macOS acting on the same key; any other
/// chord, or a Globe key set to Do Nothing, is told nothing.
@Suite struct GlobeKeyTests {
    private let fn: Set<KeyChord> = [KeyChord(modifiers: .function)]
    private let rightOption: Set<KeyChord> = [KeyChord(modifiers: .rightOption)]

    @Test func eachStoredValueIsTheActionSystemSettingsNamesIt() {
        #expect(GlobeKeyAction(appleFnUsageType: 0) == .doNothing)
        #expect(GlobeKeyAction(appleFnUsageType: 1) == .changeInputSource)
        #expect(GlobeKeyAction(appleFnUsageType: 2) == .showEmojiAndSymbols)
        #expect(GlobeKeyAction(appleFnUsageType: 3) == .startDictation)
        #expect(GlobeKeyAction(appleFnUsageType: nil) == .unset)
        #expect(GlobeKeyAction(appleFnUsageType: 9) == .unrecognized(9))
    }

    @Test func aChordHoldingFnIsToldWhatMacOSAlsoDoesAndTheSettingThatStopsIt() throws {
        let line = try #require(GlobeKeyAction.startDictation.clash(with: fn))
        #expect(line.contains("starts macOS Dictation"))
        #expect(line.contains("“Press 🌐 key to” to Do Nothing"))
        // Fn as one modifier of several still holds Fn, and one mode of several is enough.
        #expect(GlobeKeyAction.showEmojiAndSymbols.clash(with: rightOption.union([KeyChord(modifiers: .function, .leftShift)])) != nil)
        #expect(GlobeKeyAction.unset.clash(with: fn) != nil)
        #expect(GlobeKeyAction.unrecognized(9).clash(with: fn)?.contains("9") == true)
    }

    @Test func nothingIsToldWhenNoChordHoldsFnOrTheKeyDoesNothing() {
        #expect(GlobeKeyAction.startDictation.clash(with: rightOption) == nil)
        #expect(GlobeKeyAction.doNothing.clash(with: fn) == nil)
    }
}
