import Foundation

/// Signals the process is told to ignore, so that it can answer them rather than obey
/// them. Their default disposition ends the process where it stands - mid-burst, with a
/// key still down - and what a run needs instead is the chance to unwind through its own
/// ending.
///
/// [LAW:one-source-of-truth] The one place the `signal(2)`-then-`DispatchSource`
/// sequence lives. What differs between one watcher and the next is the answer, and the
/// answer is a value this takes; a second copy of the mechanism would be a second place
/// to fix a missed signal or a wrong queue. [LAW:one-type-per-behavior]
///
/// Held for as long as the answers are wanted: the sources stop when the watch is
/// released while the signals stay ignored, so a watch nobody holds is a process nothing
/// short of `SIGKILL` can stop.
public struct SignalWatch {
    private let sources: [any DispatchSourceSignal]

    /// `answer` is handed the number, off the main thread, once per delivery.
    public init(on numbers: [Int32] = [SIGINT, SIGTERM], answer: @escaping @Sendable (Int32) -> Void) {
        sources = numbers.map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { answer(number) }
            return source
        }
        sources.forEach { $0.resume() }
    }
}
