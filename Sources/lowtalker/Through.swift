import ArgumentParser
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

    /// A keyboard that is up, and what bringing it up cost.
    ///
    /// The two travel together because they are made together, and separating them would
    /// mean asking a `KeyPress` afterwards which kind it really is - a question the type
    /// exists to stop anyone needing to ask. [LAW:types-are-the-program]
    struct Opened {
        let keyboard: any KeyPress
        /// Ready to print. What is worth saying differs: the device has to be brought up
        /// and waited for - about a second of it, which is pqrs's one-second readiness
        /// poll rather than the hardware, and the number is worth printing because that
        /// wait is the whole reason a helper holds its connection open. The helper has
        /// already paid it, at its own startup, before any client existed.
        let report: String
    }

    /// [LAW:no-silent-failure] Nothing is claimed here that this side has not observed.
    /// The helper is not said to be ready, because from here it is a service that either
    /// answers or does not, and the first keystroke is what asks.
    func open(_ clock: ContinuousClock) throws -> Opened {
        let connecting = clock.now
        switch self {
        case .device:
            let device = try VirtualKeyboard()
            let connected = clock.now - connecting
            let startup = try device.start(within: .seconds(3))
            return Opened(
                keyboard: device,
                report: "connected in \(connected.milliseconds) ms, daemon answered in \(startup.answered.milliseconds) ms, keyboard ready after \(startup.ready.milliseconds) ms"
            )
        case .helper:
            let helper = HelperKeyboard()
            return Opened(
                keyboard: helper,
                report: "connected to \(Helper.machServiceName) in \((clock.now - connecting).milliseconds) ms"
            )
        }
    }
}
