import ArgumentParser
import Flavors
import Keystrokes
import KeyboardService
import VirtualKeyboard

/// Which keyboard the keystrokes go to.
///
/// [LAW:dataflow-not-control-flow] The two ways to reach the device differ in how they are
/// opened and in what they can say about being ready, and in nothing else - the layout,
/// the focus checks, the pacing and the readback are the same acts either way. So this is
/// a value the one typing command takes, and the differences live in it rather than in a
/// second command that would owe every later fix to both copies.
enum Through: String, ExpressibleByArgument, CaseIterable {
    /// The driver, opened by this process. Needs root: the socket the pqrs daemon listens
    /// on lives in a directory only root may enter.
    case device
    /// The installed helper, which is root so this process does not have to be.
    case helper

    /// A keyboard that is open, and the step that brings it up.
    ///
    /// The two travel together because they are made together, and separating them would
    /// mean asking a `KeyPress` afterwards which kind it really is - a question the type
    /// exists to stop anyone needing to ask. [LAW:types-are-the-program] Opening and
    /// bringing up are two steps and not one so the caller can register its release
    /// between them: a device that will not come up is released through the connection
    /// that was opened to it, on the same way out every other failure takes.
    struct Opened {
        let keyboard: any KeyPress
        /// Brings the keyboard up and answers with what is worth saying about it. For the
        /// device that is a wait - about a second of it, which is pqrs's one-second
        /// readiness poll rather than the hardware, and the number is worth printing
        /// because that wait is the whole reason a helper holds its connection open. The
        /// helper has already paid it, at its own startup, before any client existed.
        let bringUp: () throws -> String
    }

    /// [LAW:no-silent-failure] Nothing is claimed here that this side has not observed.
    /// The helper is not said to be ready, because from here it is a service that either
    /// answers or does not, and the first keystroke is what asks.
    func open(_ clock: ContinuousClock, flavor: Flavor) throws -> Opened {
        switch self {
        case .device:
            let connecting = clock.now
            let device = try VirtualKeyboard()
            let connected = clock.now - connecting
            return Opened(keyboard: device) {
                let startup = try device.start(within: .seconds(3))
                return "connected in \(connected.milliseconds) ms, daemon answered in \(startup.answered.milliseconds) ms, keyboard ready after \(startup.ready.milliseconds) ms"
            }
        case .helper:
            return Opened(keyboard: HelperConnection(flavor: flavor).keyboard) {
                "keystrokes go to \(flavor.machServiceName); the first one asks whether it answers"
            }
        }
    }
}
