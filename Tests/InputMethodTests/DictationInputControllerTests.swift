import AppKit
import Flavors
import InputMethod
import Testing

/// The controller hands back every key it is offered.
///
/// [LAW:behavior-not-structure] Asked by offering real events and reading the answer, not by
/// checking which methods the class overrides: a later ticket may answer keys through a
/// different door, and what must not change is that no key stops here.
@Suite struct DictationInputControllerTests {
    /// A key as something that can be carried into a test case. `NSEvent` itself cannot -
    /// it is explicitly not `Sendable` - so what travels is the description of the press and
    /// the event is built where it is used.
    struct Press: Sendable, CustomStringConvertible {
        let description: String
        let characters: String
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags.RawValue

        var event: NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .init(rawValue: modifiers), timestamp: 0,
                windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            )!
        }
    }

    /// Presses a person would notice losing: a plain letter, the dead key the checkpoint
    /// types, a Command shortcut, and Return.
    static let presses: [Press] = [
        .init(description: "the letter e", characters: "e", keyCode: 14, modifiers: 0),
        .init(description: "Option+E, the dead key", characters: "´", keyCode: 14, modifiers: NSEvent.ModifierFlags.option.rawValue),
        .init(description: "Command+Z", characters: "z", keyCode: 6, modifiers: NSEvent.ModifierFlags.command.rawValue),
        .init(description: "Return", characters: "\r", keyCode: 36, modifiers: 0),
    ]

    @Test(arguments: presses)
    func everyKeyIsHandedBack(press: Press) throws {
        let controller = try #require(
            DictationInputController(server: nil, delegate: nil, client: nil),
            "the controller could not be built to be asked"
        )
        #expect(controller.handle(press.event, client: nil) == false, "\(press) was claimed by the input method")
    }

    /// The bundle's `InputMethodServerControllerClass` is a string macOS resolves through
    /// the Objective-C runtime, so the name in project.yml and the name this class actually
    /// has are one fact in two places. A rename that moved only the Swift side would leave
    /// macOS looking up a class that no longer exists - and it looks it up at launch, long
    /// after any build succeeded. [LAW:one-source-of-truth]
    @Test func theControllerAnswersToTheNameThePlistNames() {
        #expect(NSStringFromClass(DictationInputController.self) == "DictationInputController")
    }
}
