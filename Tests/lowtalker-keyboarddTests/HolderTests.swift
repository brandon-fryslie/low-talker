import Foundation
import Testing
@testable import lowtalker_keyboardd

/// One keyboard, one client at a time, and the refusal names who has it.
/// [LAW:behavior-not-structure]
@Suite struct HolderTests {
    /// Held for the test's life: an identifier taken from an object that is gone names
    /// whatever is allocated at its address next, which was the other one.
    private let one = NSObject(), other = NSObject()
    private var first: ObjectIdentifier { ObjectIdentifier(one) }
    private var second: ObjectIdentifier { ObjectIdentifier(other) }

    @Test func aSecondClaimIsRefusedNamingTheHolder() throws {
        let holder = Holder()
        try holder.claim(first, by: 41)
        let refusal = #expect(throws: Holder.Busy.self) { try holder.claim(second, by: 42) }
        #expect(refusal?.pid == 41)
    }

    @Test func aReleaseFreesTheKeyboardForTheNextClaim() throws {
        let holder = Holder()
        try holder.claim(first, by: 41)
        holder.release(first)
        try holder.claim(second, by: 42)
    }

    /// A refused connection never held the keyboard, and its ending must not free it from
    /// under the one that does.
    @Test func aReleaseByOneThatDoesNotHoldItChangesNothing() throws {
        let holder = Holder()
        try holder.claim(first, by: 41)
        holder.release(second)
        let refusal = #expect(throws: Holder.Busy.self) { try holder.claim(second, by: 42) }
        #expect(refusal?.pid == 41)
    }
}
