import Darwin
import DarwinCalls
import Foundation
@testable import Insertion
import Testing

/// What the hotkey port did, in the order it did it, for a case to wait on.
private enum Arrival: Equatable {
    case heard(HeldModifiers)
    case told(String)
}

/// The app's end of the hotkey port on `name`, hearing `senders`, with everything it does
/// arriving on the stream it hands back.
private func hostModifiers(name: String, senders: PeerIdentity) throws -> (port: ModifierPort, arrivals: AsyncStream<Arrival>) {
    let (arrivals, continuation) = AsyncStream<Arrival>.makeStream()
    let port = try ModifierPort(
        portName: name, senders: senders, queue: DispatchQueue(label: name),
        told: { continuation.yield(.told($0.description)) }, heard: { continuation.yield(.heard($0)) })
    return (port, arrivals)
}

private let rightOptionHeld = HeldModifiers(flags: 0x80140, uptimeNanoseconds: 1_000_000_000)

/// The modifier keys cross from the input method to the app whole, in order, and from the
/// input method alone.
///
/// Both ends run in this process, which the port is told to hear: the check that matters is
/// that a sender it was not told to hear is not heard, and that is a different sender, not a
/// different process. [LAW:behavior-not-structure]
@Suite struct ModifierPortTests {
    /// The session sets the secondary-Fn bit while an arrow key is down, and an arrow key is
    /// not Fn; the Fn key down with nothing else is Fn. Every other bit is the session's.
    /// The log line says what was held whenever that is not the session's flags as given.
    @Test func theFnBitIsTheFnKeyItself() {
        let fn: UInt64 = 0x800000
        let anArrowWithRightOption = SessionModifiers(session: 0x80140 | fn, fnKeyDown: false, changedAt: 2.5)
        #expect(anArrowWithRightOption.flags == 0x80140)
        #expect(anArrowWithRightOption.description == "session 0x880140, Fn key up, held 0x80140, changed at 2.5")
        let fnAlone = SessionModifiers(session: 0x100 | fn, fnKeyDown: true, changedAt: 2.5)
        #expect(fnAlone.flags == 0x100 | fn)
        #expect(fnAlone.description == "session 0x800100, Fn key down, changed at 2.5")
        #expect(SessionModifiers(session: 0x80140, fnKeyDown: true, changedAt: 2.5).flags == 0x80140 | fn)
    }

    /// A reading is dated by the session's last change, unless that change came after the
    /// keys were read, or the session reports one from before the event it answers.
    @Test func aReadingIsDatedBetweenItsEventAndTheRead() {
        #expect(SessionModifiers.date(lastChange: 7_000.4, after: 7_000.1, readAt: 7_000.5) == 7_000.4)
        #expect(SessionModifiers.date(lastChange: 7_000.6, after: 7_000.1, readAt: 7_000.5) == 7_000.5)
        #expect(SessionModifiers.date(lastChange: 7_000.5 - 1.8e10, after: 7_000.1, readAt: 7_000.5) == 7_000.1)
        #expect(SessionModifiers.date(lastChange: 7_000.5 - 1.8e10, after: 0, readAt: 7_000.5) == 0)
    }

    /// A reading from the session now is dated no later than it was taken.
    @Test func aLiveReadingIsDatedNoLaterThanItIsTaken() {
        let reading = SessionModifiers.read()
        #expect(0...ProcessInfo.processInfo.systemUptime ~= reading.changedAt)
    }

    @Test func heldModifiersSurviveTheWire() {
        #expect(Wire.heldModifiers(of: Wire.modifiers(rightOptionHeld)) == rightOptionHeld)
        #expect(Wire.heldModifiers(of: Data(repeating: 0, count: 15)) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func changesAreHeardWholeAndInTheOrderTold() async throws {
        let name = aPortNobodyElseUses()
        let (port, arrivals) = try hostModifiers(name: name, senders: try OwnProcess.identity())
        let told = (0..<3).map { HeldModifiers(flags: UInt64(0x100 | $0 << 6), uptimeNanoseconds: UInt64($0)) }
        let sender = ModifierSender(portName: name)
        #expect(told.map(sender.tell) == Array(repeating: .told, count: 3))
        var arrived: [Arrival] = []
        for await arrival in arrivals.prefix(3) { arrived.append(arrival) }
        #expect(arrived == told.map(Arrival.heard))
        withExtendedLifetime(port) {}
    }

    /// The name is one anyone can compute, and a change heard from anyone is a press anyone
    /// can fake: a sender that is not the one named is said by name and never heard.
    @Test(.timeLimit(.minutes(1))) func aSenderThatIsNotTheInputMethodIsNotHeard() async throws {
        let name = aPortNobodyElseUses()
        let someoneElse = PeerIdentity.signed(identifier: "ai.promptctl.low-talker.test.inputmethod", certificate: String(repeating: "0", count: 40))
        let (port, arrivals) = try hostModifiers(name: name, senders: someoneElse)
        #expect(ModifierSender(portName: name).tell(rightOptionHeld) == .told)
        guard case .told(let said)? = await arrivals.first(where: { _ in true }) else {
            Issue.record("the port heard a sender it was not told to hear")
            return
        }
        #expect(said.contains("ignored modifier keys told by pid \(getpid())"))
        #expect(said.contains(someoneElse.description))
        withExtendedLifetime(port) {}
    }

    /// Bytes that are not held modifiers are said, not dropped.
    @Test(.timeLimit(.minutes(1))) func aMessageThatIsNotHeldModifiersIsSaidSo() async throws {
        let name = aPortNobodyElseUses()
        let (port, arrivals) = try hostModifiers(name: name, senders: try OwnProcess.identity())
        var remote = mach_port_t()
        try #require(lt_bootstrap_look_up(name, &remote) == KERN_SUCCESS)
        defer { mach_port_deallocate(mach_task_self_, remote) }
        let sent = Mach.send(
            Data("not modifiers".utf8), id: Wire.modifiers, to: remote, disposition: mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND),
            replyTo: Mach.noPort, timeout: aBudgetTheRunnerCannotSpend)
        try #require(sent == MACH_MSG_SUCCESS)
        #expect(await arrivals.first(where: { _ in true }) == .told(ModifierPort.Event.notUnderstood(id: Wire.modifiers, bytes: 13).description))
        withExtendedLifetime(port) {}
    }

    @Test func aChangeWithNobodyListeningSaysSo() {
        let name = aPortNobodyElseUses()
        #expect(ModifierSender(portName: name).tell(rightOptionHeld) == .nobodyIsListening(port: name))
    }

    /// The app hosts the name again each time it rebuilds its hotkey, straight after letting
    /// the last one go, so a released port has given its name up by the time the release
    /// returns. [LAW:no-ambient-temporal-coupling]
    @Test func aReleasedPortsNameCanBeHostedAgainAtOnce() throws {
        let name = aPortNobodyElseUses()
        for _ in 0..<50 {
            _ = try hostModifiers(name: name, senders: try OwnProcess.identity())
        }
    }
}
