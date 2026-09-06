import Foundation
import Keystrokes
import Testing
@testable import VirtualKeyboard

/// The bytes, on their own. Byte order is what goes wrong silently here - the frame's
/// length and id are big-endian, the usages inside a report are little-endian, and the
/// client protocol version is native - and a frame read the wrong way round is still a
/// well-formed frame. Only a test says which way round is right.
@Suite struct FramingTests {
    @Test func theHeaderIsTheBodyLengthBigEndian() throws {
        #expect(try Frame.bodyLength(header: [0, 0, 1, 0]) == 256)
        #expect(try Frame.bodyLength(header: [0, 0, 0, 1]) == 1)
        #expect(try Frame.bodyLength(header: [0, 0, 0x0f, 0xff]) == 4095)
    }

    /// A frame of nothing at all, and a header claiming more than this protocol carries,
    /// are both refused before anything allocates against them. [LAW:no-silent-failure]
    @Test func anEmptyFrameAndAnEnormousOneAreBothRefused() {
        #expect(throws: DaemonError.self) { try Frame.bodyLength(header: [0, 0, 0, 0]) }
        #expect(throws: DaemonError.self) { try Frame.bodyLength(header: [0xff, 0xff, 0xff, 0xff]) }
        #expect(throws: DaemonError.self) { try Frame.bodyLength(header: [0, 0, 0x10, 0x01]) }
        #expect(throws: Never.self) { try Frame.bodyLength(header: [0, 0, 0x10, 0x00]) }
    }

    /// Every byte of a request frame, written out: length, type, then eight bytes of id
    /// most significant first.
    @Test func aRequestFrameIsLengthThenTypeThenAnEightByteBigEndianID() {
        #expect(Frame.request(id: 0x0102_0304_0506_0708, payload: [0xaa, 0xbb]).bytes
                == [0, 0, 0, 11, 4, 1, 2, 3, 4, 5, 6, 7, 8, 0xaa, 0xbb])
        #expect(Frame.response(id: 1, payload: []).bytes == [0, 0, 0, 9, 5, 0, 0, 0, 0, 0, 0, 0, 1])
    }

    /// The frames the protocol gives no id carry none, and there is nothing on the case to
    /// ask for one. The spike answered 0 in the id position for these, which has the shape
    /// of a real id while meaning "absent" - a state the protocol does not have.
    /// [LAW:types-are-the-program]
    @Test func aFrameTheProtocolGivesNoIDHasNoIDToAskFor() throws {
        let heartbeat = Frame.control(.heartbeat, payload: [])
        #expect(heartbeat.bytes == [0, 0, 0, 1, 0])
        #expect(try Frame.decode(body: [0]) == .control(.heartbeat, payload: []))
        #expect(try Frame.decode(body: [3]) == .control(.healthCheckResponse, payload: []))
        // Its payload is kept rather than dropped: a decode that discards what it does not
        // currently read is a decode that lies about the wire.
        #expect(try Frame.decode(body: [1, 9, 9]) == .control(.userData, payload: [9, 9]))
    }

    @Test func everyFrameRoundTripsThroughItsOwnDecode() throws {
        let frames: [Frame] = [
            .control(.heartbeat, payload: []),
            .control(.userData, payload: [7, 8, 9]),
            .control(.healthCheck, payload: []),
            .control(.healthCheckResponse, payload: []),
            .request(id: 0xdead_beef_cafe_0001, payload: [7, 8, 9]),
            .response(id: 1, payload: [4, 1]),
        ]
        for frame in frames {
            #expect(try Frame.decode(body: Array(frame.bytes.dropFirst(4))) == frame)
        }
    }

    /// A body of no bytes has no type byte, so there is no frame to name - and the read
    /// that produced it saw a length this side already refuses. [LAW:no-silent-failure]
    @Test func aFrameShorterThanTheTypeAndIDItsBytesPromiseIsRefused() {
        #expect(throws: DaemonError.self) { try Frame.decode(body: []) }
        #expect(throws: DaemonError.self) { try Frame.decode(body: [4, 0, 0, 0]) }
        #expect(throws: DaemonError.self) { try Frame.decode(body: [99]) }
    }

    /// Pairs of (status, value) in the order the daemon sent them, any non-zero meaning
    /// true. Transposed, a pair records the wrong status and nothing about it looks wrong.
    @Test func aStatusPayloadDecodesAsOrderedPairs() throws {
        let pairs = try DaemonConnection.statusPairs([1, 1, 4, 0, 2, 0xff])
        #expect(pairs.map(\.0) == [.driverActivated, .keyboardReady, .driverConnected])
        #expect(pairs.map(\.1) == [true, false, true])
        #expect(try DaemonConnection.statusPairs([]).isEmpty)
    }

    @Test func aStatusPayloadThatIsNotPairsIsRefused() {
        #expect(throws: DaemonError.self) { try DaemonConnection.statusPairs([1, 1, 4]) }
        #expect(throws: DaemonError.self) { try DaemonConnection.statusPairs([99, 1]) }
    }
}
