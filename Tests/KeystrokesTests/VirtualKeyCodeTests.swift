import Testing
@testable import Keystrokes

/// The key code table read backwards, which is only an answer if no usage appears twice.
@Suite struct VirtualKeyCodeTests {
    /// Every key code with a usage comes back from that usage, so the inverse names one key
    /// and never whichever of two a dictionary happened to visit first.
    @Test func theTableReadsTheSameBothWays() {
        for code in UInt16(0)...0x7F {
            guard let usage = Usage(virtualKeyCode: code) else { continue }
            #expect(usage.virtualKeyCode == code, "usage 0x\(String(usage.rawValue, radix: 16)) reads back as a different key code than 0x\(String(code, radix: 16))")
        }
    }

    @Test func aUsageNoKeyCodeNamesHasNone() {
        #expect(Usage(rawValue: 0xFF).virtualKeyCode == nil)
    }
}
