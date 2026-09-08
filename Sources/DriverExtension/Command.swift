import Foundation

/// One command run against the machine, and everything it said.
///
/// Small on purpose: a reading needs a status and two streams, and a general process
/// wrapper would be a second thing to maintain for the sake of arguments nobody passes.
/// It lives beside the driver probe because that is where the first reading was taken;
/// onboarding takes its own the same way rather than growing a second runner.
public struct Command {
    public let tool: URL
    public let arguments: [String]

    public init(_ tool: String, _ arguments: String...) {
        self.tool = URL(fileURLWithPath: tool)
        self.arguments = arguments
    }

    public struct Output {
        public let status: Int32
        public let stdout: String
        public let stderr: String

        public init(status: Int32, stdout: String, stderr: String) {
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
        }
        /// What a reader should be shown when the command failed: tools split their
        /// complaints across both streams and which one carried it is not the reader's
        /// problem.
        public var merged: String {
            [stdout, stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    public func run() throws -> Output {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let outDrain = Drain(out.fileHandleForReading)
        let errDrain = Drain(err.fileHandleForReading)
        try process.run()
        process.waitUntilExit()
        return Output(
            status: process.terminationStatus,
            stdout: outDrain.text(),
            stderr: errDrain.text()
        )
    }
}

/// One stream, read from before the child starts until the stream ends.
///
/// A command holds two of these at once, and that is the whole reason the type exists: a
/// child whose pipe fills blocks in `write(2)` until someone reads it, so a stream that
/// waits its turn is a stream whose turn can never come - the child cannot reach the exit
/// that would end the read we are waiting on. [LAW:no-ambient-temporal-coupling] Both
/// draining from the start leaves no order to get wrong, rather than an order to get right.
private final class Drain: @unchecked Sendable {
    // [LAW:no-shared-mutable-globals] `bytes` is written on the handler's queue and read on
    // the caller's; the lock is the named owner of that crossing.
    private let lock = NSLock()
    private var bytes = Data()
    private let ended = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        handle.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            lock.withLock { bytes.append(chunk) }
            // An empty read is EOF, and it is the only thing that says the stream ended.
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                ended.signal()
            }
        }
    }

    func text() -> String {
        ended.wait()
        return lock.withLock { String(decoding: bytes, as: UTF8.self) }
    }
}
