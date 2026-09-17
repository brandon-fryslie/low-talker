import Foundation
import Signals

/// A stop, as a value the run reads rather than a way out that skips the run's own
/// ending.
///
/// SIGINT's default disposition ends a process where it stands, so an interrupt during a
/// burst leaves a key down with nothing left to release it, and macOS repeats that key
/// into whatever app comes forward next. Ignored as a signal and watched as a source
/// instead, it becomes something the run can read and stop for, unwinding through the
/// same release every other failure takes. [LAW:dataflow-not-control-flow] The app raises
/// one the same way when a user cancels: a cancel and a Ctrl-C are one event to the
/// keystroke they stop.
///
/// Being watched has a price worth stating plainly: the signal no longer ends a blocking
/// read either, so it is seen only where something asks. Every loop that waits on another
/// process asks - raising the app, polling the screen, each keystroke of the burst - and
/// so does each step between them. What is left is the daemon's own reads, so an
/// interrupt arriving inside one is seen when that read returns, at most two seconds
/// later.
public final class Interrupt: @unchecked Sendable {
    private let lock = NSLock()
    private var raised: Int32?
    private var watch: SignalWatch?

    /// Raised only by `raise`: the caller's own cancel.
    public init() {}

    /// Raised by the process's signals, for a command line that is stopped with Ctrl-C.
    public static func watched(_ numbers: [Int32] = [SIGINT, SIGTERM]) -> Interrupt {
        let interrupt = Interrupt()
        interrupt.watch = SignalWatch(on: numbers) { interrupt.raise($0) }
        return interrupt
    }

    /// The first raise is the one reported; a second changes nothing, so the run is
    /// stopped once for one reason.
    public func raise(_ number: Int32) {
        lock.lock()
        defer { lock.unlock() }
        raised = raised ?? number
    }

    /// [LAW:no-silent-failure] An interrupt is a named failure like any other, so it
    /// travels the same path and is reported with the same count beside it.
    public func check() throws {
        if let raised = number { throw Interrupted(number: raised) }
    }

    /// Whether one has been raised, for a run that answers an interrupt as an outcome of its
    /// own rather than as a failure - a hardware reading stops, puts the Mac back and says it
    /// was interrupted, where a burst throws. Same fact, read without the throw.
    public var isRaised: Bool { number != nil }

    private var number: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }
}

public struct Interrupted: Error, CustomStringConvertible {
    public let number: Int32

    public init(number: Int32) {
        self.number = number
    }

    public var description: String { "interrupted by signal \(number)" }
}
