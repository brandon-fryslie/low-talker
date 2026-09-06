import Foundation
import Testing
@testable import VirtualKeyboard

/// A daemon that answers every request and, once the keyboard is initialized, pushes the
/// three statuses the real one pushes.
@Sendable private func daemonThatComesUp(_ frame: Frame, _ fake: FakeDaemon) throws {
    guard case .request(let id, let payload) = frame else { return }
    try fake.send(.response(id: id, payload: []))
    if requestSent(payload).request == DaemonConnection.Request.keyboardInitialize.rawValue {
        try fake.push([(.driverActivated, true), (.driverConnected, true)])
        try fake.push([(.keyboardReady, true)])
    }
}

private func keyboard(on fake: FakeDaemon, reportTimeout: Duration = .seconds(2)) -> VirtualKeyboard {
    VirtualKeyboard(daemon: DaemonConnection(fileDescriptor: fake.clientDescriptor), reportTimeout: reportTimeout)
}

/// The reports the device actually put on the wire, in order.
private func reports(_ fake: FakeDaemon) -> [[UInt8]] {
    fake.requestPayloads.map(requestSent).filter { $0.request == DaemonConnection.Request.postKeyboardInputReport.rawValue }.map(\.bytes)
}

private func report(modifiers: UInt8, _ usages: [UInt16] = []) -> [UInt8] {
    let padded = usages + Array(repeating: 0, count: KeyboardReport.capacity - usages.count)
    return [1, modifiers, 0] + padded.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
}

@Suite struct StartupTests {
    /// The parameters are three uint64, little-endian, vendor then product then country.
    /// The plausible reading - two 16-bit ids and a byte - is five bytes long, well formed,
    /// and initializes a device that is not the one asked for.
    @Test func initializeCarriesTheClientVersionAndThreeLittleEndianUInt64Parameters() throws {
        let fake = FakeDaemon(handling: daemonThatComesUp)
        try keyboard(on: fake).start(within: .seconds(2))
        let sent = requestSent(fake.requestPayloads[0])
        #expect(sent.version == 7)
        #expect(sent.request == DaemonConnection.Request.keyboardInitialize.rawValue)
        #expect(sent.bytes == [0xc0, 0x16, 0, 0, 0, 0, 0, 0,
                               0xdb, 0x27, 0, 0, 0, 0, 0, 0,
                               0, 0, 0, 0, 0, 0, 0, 0])
    }

    /// Readiness is a value the daemon sends and this waits for, never a sleep. A daemon
    /// that takes its time is waited out; one that answers sooner is not waited on longer.
    @Test func startWaitsForTheDaemonsWordAndReturnsWhenItComes() throws {
        let fake = FakeDaemon { frame, fake in
            guard case .request(let id, let payload) = frame else { return }
            try fake.send(.response(id: id, payload: []))
            if requestSent(payload).request == DaemonConnection.Request.keyboardInitialize.rawValue {
                Thread.sleep(forTimeInterval: 0.2)
                try fake.push([(.keyboardReady, true)])
            }
        }
        let startup = try keyboard(on: fake).start(within: .seconds(5))
        #expect(startup.ready > .milliseconds(180))
        // Well inside the five seconds it was given: it returned when told, not on a timer.
        #expect(startup.ready < .seconds(2))
    }

    /// A driver built for another protocol accepts reports and then does something other
    /// than what they say, so skew is a hard failure with no degraded mode to continue
    /// into. [LAW:no-silent-failure]
    @Test func aDriverVersionMismatchStopsTheRunRatherThanWarning() {
        let fake = FakeDaemon { frame, fake in
            guard case .request(let id, _) = frame else { return }
            try fake.send(.response(id: id, payload: []))
            try fake.push([(.driverVersionMismatched, true)])
        }
        #expect(throws: DaemonError.driverVersionMismatched) { try keyboard(on: fake).start(within: .seconds(2)) }
    }

    /// A daemon that says nothing is a named failure at the deadline, not a wait without
    /// end. [LAW:no-silent-failure]
    @Test func aDaemonThatNeverAnswersIsAFailureWithAName() {
        let fake = FakeDaemon { _, _ in }
        #expect(throws: DaemonError.silent) { try keyboard(on: fake).start(within: .milliseconds(200)) }
    }

    /// The daemon health-checks its clients, and a client that does not answer is one it
    /// drops. The answer goes out from inside the wait for something else.
    @Test func aHealthCheckIsAnsweredEvenWhileWaitingForSomethingElse() throws {
        let fake = FakeDaemon { frame, fake in
            guard case .request(let id, _) = frame else { return }
            try fake.send(.control(.healthCheck, payload: []))
            try fake.send(.response(id: id, payload: []))
            try fake.push([(.keyboardReady, true)])
        }
        try keyboard(on: fake).start(within: .seconds(2))
        #expect(fake.awaitFrame(.control(.healthCheckResponse, payload: [])))
    }
}

@Suite struct KeysDownTests {
    /// Every report is a reading of the keys that are down, and a caller never composes
    /// one. [LAW:one-source-of-truth] A report that could disagree with what is held has
    /// exactly one failure mode, and it is the one this whole epic is about.
    @Test func everyReportIsTheKeysDownAndNothingElse() throws {
        let fake = FakeDaemon(handling: daemonThatComesUp)
        let device = keyboard(on: fake)
        try device.start(within: .seconds(2))
        try device.down(Usage(rawValue: 0x04))
        try device.down(Usage(rawValue: 0x05))
        #expect(device.keysDown == [Usage(rawValue: 0x04), Usage(rawValue: 0x05)])
        try device.up(Usage(rawValue: 0x04))
        try device.releaseAll()
        #expect(device.keysDown.isEmpty)
        #expect(reports(fake) == [
            report(modifiers: 0, [0x04]),
            report(modifiers: 0, [0x04, 0x05]),
            report(modifiers: 0, [0x05]),
            report(modifiers: 0),
        ])
    }

    /// A modifier is a usage like any other, and the bit it sets in the report is derived
    /// from the usage rather than kept beside it. Left shift is 0xE1 and bit 0x02 because
    /// 0xE1 is the second of the eight, not because a table says so.
    @Test func aModifierIsAUsageAndItsBitComesFromTheUsage() throws {
        let fake = FakeDaemon(handling: daemonThatComesUp)
        let device = keyboard(on: fake)
        try device.start(within: .seconds(2))
        try device.down(.leftShift)
        try device.down(Usage(rawValue: 0x04))
        try device.up(Usage(rawValue: 0x04))
        try device.up(.leftShift)
        #expect(reports(fake) == [
            report(modifiers: 0x02),
            report(modifiers: 0x02, [0x04]),
            report(modifiers: 0x02),
            report(modifiers: 0),
        ])
    }

    /// All eight, each in its own bit and none in another's.
    @Test func theEightModifiersCarryTheEightBitsInOrder() throws {
        let modifiers: [Usage] = [.leftControl, .leftShift, .leftOption, .leftCommand, .rightControl, .rightShift, .rightOption, .rightCommand]
        for (index, modifier) in modifiers.enumerated() {
            #expect(modifier.modifierBit == UInt8(1 << index))
        }
        #expect(Usage(rawValue: 0x04).modifierBit == nil)
        #expect(Usage(rawValue: 0xDF).modifierBit == nil)
        #expect(Usage(rawValue: 0xE8).modifierBit == nil)
        // All eight held at once is every bit set and no key in the usage field.
        #expect(try KeyboardReport(held: Set(modifiers)).bytes == report(modifiers: 0xff))
    }

    /// One set of keys held has one encoding, so a report can be compared against a
    /// capture: without an order, the usage field would vary run to run with a hash seed.
    @Test func theUsagesGoOutInOrderSoOneSetHasOneEncoding() throws {
        let held: Set<Usage> = [Usage(rawValue: 0x0a), Usage(rawValue: 0x04), Usage(rawValue: 0x07)]
        #expect(try KeyboardReport(held: held).bytes == report(modifiers: 0, [0x04, 0x07, 0x0a]))
    }

    /// The usage field is fixed width. More keys than it carries is refused by name rather
    /// than by dropping one, which would be a key held that no report mentions.
    @Test func moreKeysThanOneReportCarriesIsRefused() throws {
        let thirtyTwo = Set((0x04...0x23).map { Usage(rawValue: UInt16($0)) })
        #expect(thirtyTwo.count == KeyboardReport.capacity)
        #expect(throws: Never.self) { try KeyboardReport(held: thirtyTwo) }
        #expect(throws: TooManyKeys.self) { try KeyboardReport(held: thirtyTwo.union([Usage(rawValue: 0x24)])) }
        // Modifiers are not in that field, so eight of them cost nothing against the cap.
        #expect(throws: Never.self) { try KeyboardReport(held: thirtyTwo.union([.leftShift, .rightCommand])) }
    }

    /// A key recorded as down before the report goes out, deliberately: if the post fails
    /// after the driver saw it, a record that already says so is the one releaseAll can
    /// act on. The other order forgets keys that are really held.
    @Test func aKeyIsRecordedDownEvenWhenItsReportFails() throws {
        let fake = FakeDaemon { frame, fake in
            guard case .request(let id, let payload) = frame else { return }
            guard requestSent(payload).request != DaemonConnection.Request.postKeyboardInputReport.rawValue else { return }
            try fake.send(.response(id: id, payload: []))
        }
        let device = keyboard(on: fake, reportTimeout: .milliseconds(200))
        #expect(throws: DaemonError.silent) { try device.down(.leftShift) }
        #expect(device.keysDown == [.leftShift])
    }

    /// reset clears the device's own idea of what is held as well as this side's.
    @Test func resetAsksTheDaemonToClearTheDeviceAndForgetsWhatWasHeld() throws {
        let fake = FakeDaemon(handling: daemonThatComesUp)
        let device = keyboard(on: fake)
        try device.start(within: .seconds(2))
        try device.down(.leftShift)
        try device.reset()
        #expect(device.keysDown.isEmpty)
        let sent = fake.requestPayloads.map(requestSent)
        #expect(sent.last?.request == DaemonConnection.Request.keyboardReset.rawValue)
        #expect(sent.last?.bytes.isEmpty == true)
    }
}
