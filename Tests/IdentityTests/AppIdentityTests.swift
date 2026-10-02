import Identity
import Testing

/// The names macOS keys LowTalker by.
struct AppIdentityTests {
    /// Every name macOS files this program under is its own: the input method bundle taking
    /// the app's identifier, say, is a second registrant losing to a first.
    @Test func noTwoNamesMacOSKeysOnCollide() {
        let names = [
            AppIdentity.bundleIdentifier,
            AppIdentity.inputMethodBundleIdentifier,
            AppIdentity.inputSourceIdentifier,
            AppIdentity.inputMethodConnectionName,
            AppIdentity.inputMethodPortName,
            AppIdentity.hotkeyPortName,
        ]
        #expect(Set(names).count == names.count, "two names collide: \(names)")
    }

    /// The input method's names sit under the app's, and its grown names sit under its
    /// bundle's.
    @Test func theInputMethodsNamesAreUnderItsBundle() {
        #expect(AppIdentity.inputMethodBundleIdentifier.hasPrefix(AppIdentity.bundleIdentifier + "."))
        #expect(AppIdentity.inputSourceIdentifier.hasPrefix(AppIdentity.inputMethodBundleIdentifier + "."))
        #expect(AppIdentity.inputMethodConnectionName.hasPrefix(AppIdentity.inputMethodBundleIdentifier))
        #expect(AppIdentity.inputMethodPortName.hasPrefix(AppIdentity.inputMethodBundleIdentifier))
    }

    /// The names, spelled out.
    ///
    /// Pinned rather than derived, because these strings are what macOS itself files the
    /// app, its grants, a registered input source and a published connection under on
    /// somebody's Mac. Changing one is not a rename: it orphans what an installed copy
    /// already registered, and that copy is not here to be recompiled. So the test exists
    /// to make that change loud rather than to describe the code.
    ///
    /// The `.inputmethod` segment is followed by `.dictation` and not left at the end, and
    /// that is the load-bearing part: measured on macOS Tahoe, a bundle whose identifier
    /// ENDS in `.inputmethod` registers nothing at all while `TISRegisterInputSource` still
    /// answers noErr. [LAW:no-silent-failure] A "tidy-up" that dropped the leaf would be
    /// silently uninstallable, which is exactly what pinning is for.
    @Test func theseAreTheExactNamesMacOSFiles() {
        #expect(AppIdentity.bundleIdentifier == "ai.promptctl.low-talker")
        #expect(AppIdentity.inputMethodBundleIdentifier == "ai.promptctl.low-talker.inputmethod.dictation")
        #expect(AppIdentity.inputSourceIdentifier == "ai.promptctl.low-talker.inputmethod.dictation.text")
        #expect(AppIdentity.inputMethodConnectionName == "ai.promptctl.low-talker.inputmethod.dictation_Connection")
    }

    /// The server port, spelled out: a client's `base_url` is typed by hand, so moving the
    /// port breaks every pipeline pointed at it, and that should be loud.
    @Test func thisIsTheServerPortClientsAreGiven() {
        #expect(AppIdentity.serverPort == 8610)
    }

    /// The rule the names above exist to satisfy, stated as a property: macOS takes an input
    /// method only if `inputmethod` is a dot-delimited segment of its bundle identifier AND
    /// something follows it.
    @Test func theInputMethodSegmentIsNeverTheLastOne() {
        let segments = AppIdentity.inputMethodBundleIdentifier.split(separator: ".").map(String.init)
        let at = segments.firstIndex(of: "inputmethod")
        #expect(at != nil, "the input method identifier carries no `inputmethod` segment: \(AppIdentity.inputMethodBundleIdentifier)")
        #expect(at.map { $0 < segments.count - 1 } == true,
                "the `inputmethod` segment is the last one, which macOS refuses: \(AppIdentity.inputMethodBundleIdentifier)")
    }
}
