import Foundation
import KeyboardService
import Keystrokes
import Pointing
import Synchronization
import Testing
@testable import lowtalker_keyboardd

/// The devices as the helper serves them, over recording devices of the test's own: what
/// the wire may carry that the device cannot, and what a client leaving lets go of.
@Suite struct DevicesTests {
    final class RecordingKeyboard: KeyPress {
        private let recorded = Mutex<[String]>([])
        let refusesRelease: Bool

        init(refusesRelease: Bool = false) { self.refusesRelease = refusesRelease }

        var log: [String] { recorded.withLock { $0 } }

        func down(_ usage: Usage) throws { recorded.withLock { $0.append("down \(usage.rawValue)") } }
        func releaseAll() throws {
            recorded.withLock { $0.append("up") }
            if refusesRelease { throw Refused() }
        }
    }

    final class RecordingMouse: Pointing {
        private let recorded = Mutex<[String]>([])

        var log: [String] { recorded.withLock { $0 } }

        func down(_ button: Button) throws { recorded.withLock { $0.append("down \(button.rawValue)") } }
        func releaseAll() throws { recorded.withLock { $0.append("up") } }
        func move(by delta: Move) throws { recorded.withLock { $0.append("move \(delta.x.value) \(delta.y.value)") } }
        func scroll(by delta: Scroll) throws { recorded.withLock { $0.append("scroll \(delta.vertical.value) \(delta.horizontal.value)") } }
    }

    struct Refused: Error {}

    /// The reply, as the client gets it: nil, or the refusal.
    private func answer(_ call: (@escaping (Error?) -> Void) -> Void) -> Error? {
        var answered: Error?
        call { answered = $0 }
        return answered
    }

    /// A button the device has no bit for, or a count the descriptor does not admit, is
    /// refused by name and never reaches the device. [LAW:parse-dont-validate]
    @Test func valuesTheDeviceCannotCarryAreRefusedBeforeItSeesThem() {
        let mouse = RecordingMouse()
        let devices = Devices(keyboard: RecordingKeyboard(), mouse: mouse)
        #expect(answer { devices.buttonDown(0, reply: $0) }?.localizedDescription == "button 0 is not one of the 32 the device has a bit for")
        #expect(answer { devices.buttonDown(33, reply: $0) }?.localizedDescription == "button 33 is not one of the 32 the device has a bit for")
        #expect(answer { devices.move(x: -128, y: 0, reply: $0) }?.localizedDescription == "-128 is outside the -127 through 127 a report carries")
        #expect(answer { devices.scroll(vertical: 1, horizontal: -128, reply: $0) }?.localizedDescription == "-128 is outside the -127 through 127 a report carries")
        #expect(mouse.log.isEmpty)
    }

    /// What the device can carry reaches it as asked, and the reply is nil.
    @Test func valuesTheDeviceCanCarryReachIt() {
        let keyboard = RecordingKeyboard()
        let mouse = RecordingMouse()
        let devices = Devices(keyboard: keyboard, mouse: mouse)
        #expect(answer { devices.down(usage: 0x04, reply: $0) } == nil)
        #expect(answer { devices.buttonDown(3, reply: $0) } == nil)
        #expect(answer { devices.move(x: 127, y: -127, reply: $0) } == nil)
        #expect(answer { devices.scroll(vertical: 1, horizontal: -1, reply: $0) } == nil)
        #expect(answer { devices.releaseButtons(reply: $0) } == nil)
        #expect(answer { devices.releaseAll(reply: $0) } == nil)
        #expect(keyboard.log == ["down 4", "up"])
        #expect(mouse.log == ["down 3", "move 127 -127", "scroll 1 -1", "up"])
    }

    /// A refusal crosses as the one error a client can decode, carrying the words.
    @Test func aRefusalCrossesAsAnNSErrorCarryingItsDescription() throws {
        let devices = Devices(keyboard: RecordingKeyboard(), mouse: RecordingMouse())
        let error = try #require(answer { devices.buttonDown(0, reply: $0) }) as NSError
        #expect(error.domain == Helper.machServiceName)
        #expect(error.localizedDescription == "button 0 is not one of the 32 the device has a bit for")
    }

    /// A client leaving has both devices released, the mouse whatever the keyboard said.
    @Test func releasingEverythingReleasesBothDevicesWhateverTheKeyboardAnswers() {
        let keyboard = RecordingKeyboard(refusesRelease: true)
        let mouse = RecordingMouse()
        Devices(keyboard: keyboard, mouse: mouse).releaseEverything(because: "the client went away")
        #expect(keyboard.log == ["up"])
        #expect(mouse.log == ["up"])
    }
}
