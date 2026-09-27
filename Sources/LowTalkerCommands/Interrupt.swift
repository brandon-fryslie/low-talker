import Foundation
import Signals

/// A stop, as a value the run reads rather than a way out that skips the run's own
/// ending.
///
/// SIGINT's default disposition ends a process where it stands, so an interrupt during a
/// hardware reading would leave the Mac in whatever state the reading had put it in. Ignored
/// as a signal and watched as a source instead, it becomes something the run can read and
/// stop for, unwinding through the same path every other ending takes.
/// [LAW:dataflow-not-control-flow]
///
/// Being watched has a price worth stating plainly: the signal no longer ends a blocking
/// read either, so it is seen only where something asks.
final class Interrupt: @unchecked Sendable {
    private let lock = NSLock()
    private var raised: Int32?
    private var watch: SignalWatch?

    private init() {}

    /// Raised by the process's signals, for a command line that is stopped with Ctrl-C.
    static func watched(_ numbers: [Int32] = [SIGINT, SIGTERM]) -> Interrupt {
        let interrupt = Interrupt()
        interrupt.watch = SignalWatch(on: numbers) { interrupt.raise($0) }
        return interrupt
    }

    /// The first raise is the one reported; a second changes nothing, so the run is
    /// stopped once for one reason.
    private func raise(_ number: Int32) {
        lock.lock()
        defer { lock.unlock() }
        raised = raised ?? number
    }

    /// [LAW:no-silent-failure] An interrupt is a named failure like any other, so it
    /// travels the same path.
    func check() throws {
        if let raised = number { throw Interrupted(number: raised) }
    }

    /// Whether one has been raised, for a run that answers an interrupt as an outcome of its
    /// own rather than as a failure - a hardware reading stops, puts the Mac back and says it
    /// was interrupted. Same fact, read without the throw.
    var isRaised: Bool { number != nil }

    private var number: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }
}

struct Interrupted: Error, CustomStringConvertible {
    let number: Int32

    var description: String { "interrupted by signal \(number)" }
}
