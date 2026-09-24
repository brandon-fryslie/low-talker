import Foundation
import Testing
@testable import LowTalkerCore

/// The app's two choices as every reader sees them: what the app keeps, the CLI reads back
/// under the same keys. [LAW:behavior-not-structure]
@Suite struct KeptChoicesTests {
    /// A defaults domain of the test's own, removed after, so no real installation's
    /// choices are read or written.
    private static func withDomain(_ body: (UserDefaults) throws -> Void) throws {
        let name = "ai.promptctl.low-talker.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func aChoiceKeptIsTheChoiceReadBack() throws {
        try Self.withDomain { defaults in
            let kept = KeptChoices(defaults)
            #expect(kept.delivery == nil && kept.source == nil)
            kept.delivery = .inputMethod
            kept.source = .eventTap
            let readElsewhere = KeptChoices(defaults)
            #expect(readElsewhere.delivery == .inputMethod)
            #expect(readElsewhere.source == .eventTap)
        }
    }

    /// The key on disk is every installed copy's stored answer, so its spelling is part of
    /// the contract: an installation that chose the virtual keyboard wrote this word here.
    @Test func theDeliveryIsKeptUnderTheWordInstalledCopiesAlreadyWrote() throws {
        try Self.withDomain { defaults in
            defaults.set("virtualKeyboard", forKey: "inputMethod")
            defaults.set("registeredHotKey", forKey: "hotkeySource")
            #expect(KeptChoices(defaults).delivery == .virtualKeyboard)
            #expect(KeptChoices(defaults).source == .registeredHotKey)
        }
    }

    /// A stored word naming no choice reads as never asked, so the question comes back.
    @Test func aWordNamingNoChoiceReadsAsNeverAsked() throws {
        try Self.withDomain { defaults in
            defaults.set("carrierPigeon", forKey: "inputMethod")
            #expect(KeptChoices(defaults).delivery == nil)
        }
    }
}
