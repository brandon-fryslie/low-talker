import LowTalkerCore
import Testing

@Suite struct PasteMenuItemTests {
    /// Accessibility reports the capital letter; an empty modifier mask is Cmd alone.
    @Test func plainCmdVIsTheCapitalWithNoModifierBits() {
        #expect(PasteMenuItem.isPlainCmdV(cmdChar: "V", modifiers: 0))
        #expect(!PasteMenuItem.isPlainCmdV(cmdChar: "v", modifiers: 0))
        #expect(!PasteMenuItem.isPlainCmdV(cmdChar: "V", modifiers: 2))
        #expect(!PasteMenuItem.isPlainCmdV(cmdChar: "C", modifiers: 0))
        #expect(!PasteMenuItem.isPlainCmdV(cmdChar: nil, modifiers: 0))
        #expect(!PasteMenuItem.isPlainCmdV(cmdChar: "V", modifiers: nil))
    }
}
