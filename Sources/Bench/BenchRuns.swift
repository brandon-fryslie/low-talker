import Foundation
import LowTalkerCore
import os

/// How a bench run ended.
public enum BenchEnding: Hashable, Sendable {
    case finished
    case cancelled
    case failed(String)
}

/// The app's one bench run at a time: starting it, cancelling it, telling the log what it
/// does, and refusing a dictation press while it holds the Neural Engine, so neither a press
/// nor a reading is measured against the other.
///
/// [LAW:single-enforcer] The window and `LowTalker --bench` both start their run here, so
/// every run is logged by this one owner, an event per row, and the refusal reads the same
/// state the run sets. [LAW:nothing-unseen]
@MainActor
public final class BenchRuns {
    private var current: Task<Void, Never>?
    /// Rows the current run has emitted, for the line that says how it ended.
    private var rows = 0
    private let log: @Sendable (String) -> Void

    /// `log` is where each event's line goes; the unified log unless a test listens.
    public init(log: @escaping @Sendable (String) -> Void = BenchRuns.unifiedLog) {
        self.log = log
    }

    public var isRunning: Bool { current != nil }

    /// Throws while a run holds the engine; what a press asks before it takes the engine.
    public func admitPress() throws(BenchmarkRunning) {
        if isRunning { throw BenchmarkRunning() }
    }

    /// Runs `work`, logging and forwarding each event it emits and how it ended. Refused while
    /// another run is going. The returned task ends once `ended` has been told.
    @discardableResult
    public func start(
        _ summary: String,
        work: @escaping @Sendable (_ emit: @escaping @Sendable (BenchEvent) async -> Void) async throws -> Void,
        events: @escaping @MainActor (BenchEvent) -> Void,
        ended: @escaping @MainActor (BenchEnding) -> Void
    ) throws(BenchmarkRunning) -> Task<Void, Never> {
        try admitPress()
        log("bench: started \(summary)")
        rows = 0
        let task = Task { [log] in
            let ending: BenchEnding
            do {
                try await work { event in
                    await MainActor.run {
                        switch event {
                        case .loading(let model): log("bench: loading \(model)")
                        case .row(let row):
                            self.rows += 1
                            log("bench row: \(row.fields)")
                        }
                        events(event)
                    }
                }
                ending = .finished
            } catch {
                // A load or a decode cancelled midway may throw its own error rather than
                // CancellationError; cancelled is what the person did, so it is what is said.
                ending = Task.isCancelled || error is CancellationError ? .cancelled : .failed("\(error)")
            }
            log("bench: \(Self.describe(ending, rows: rows))")
            current = nil
            ended(ending)
        }
        current = task
        return task
    }

    /// Stops the run at its next hold.
    public func cancel() {
        current?.cancel()
    }

    /// How a run ended, in the words its last log line and the window say it.
    public static func describe(_ ending: BenchEnding, rows: Int) -> String {
        switch ending {
        case .finished: "finished, \(rows) rows"
        case .cancelled: "cancelled after \(rows) rows"
        case .failed(let reason): "failed after \(rows) rows: \(reason)"
        }
    }

    /// The `bench` category of the app's subsystem, every line public: rows are fixture
    /// speech and numbers, never anything a person dictated.
    public static let unifiedLog: @Sendable (String) -> Void = {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "lowtalker", category: "bench")
        return { logger.notice("\($0, privacy: .public)") }
    }()
}

/// A dictation press made while a bench run holds the engine.
public struct BenchmarkRunning: Error, Equatable, CustomStringConvertible {
    public init() {}

    public var description: String {
        "a benchmark is running; dictation is back once it ends or is cancelled in the Benchmark window"
    }
}
