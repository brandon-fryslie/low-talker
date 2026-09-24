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

    /// Runs the command in front of the person at the terminal rather than behind a pipe:
    /// sudo has to reach them for a password, and an installer's progress is theirs to
    /// watch. Its standard output goes to this process's standard error, so a verb whose
    /// own stdout is a value a caller reads - a path, a verdict - keeps it clean.
    ///
    /// Spawned directly and not through `Process`, which puts its child in a process group
    /// of its own - measured: the child's pgid was its own pid. A child outside the
    /// terminal's foreground group is stopped the moment sudo opens the terminal to ask for
    /// a password, and Ctrl-C never reaches it. This child stays in ours.
    ///
    /// Staying in ours means Ctrl-C reaches this process too, so while the child runs this
    /// process ignores it, as `system(3)` and every shell do: the child alone dies of it, its
    /// status comes back as a refusal, and the caller's cleanup runs instead of dying with
    /// it. The child is handed the default dispositions and an empty mask, never our ignore
    /// or a blocked signal inherited from whoever started us.
    public func perform() throws -> Int32 {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDOUT_FILENO)
        var interrupts = sigset_t()
        sigemptyset(&interrupts)
        sigaddset(&interrupts, SIGINT)
        sigaddset(&interrupts, SIGQUIT)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setsigdefault(&attributes, &interrupts)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        let interruptWas = signal(SIGINT, SIG_IGN), quitWas = signal(SIGQUIT, SIG_IGN)
        defer {
            signal(SIGINT, interruptWas)
            signal(SIGQUIT, quitWas)
        }
        let argv = ([tool.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, tool.path, &actions, &attributes, argv, environ)
        guard spawned == 0 else { throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO) }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        // WIFEXITED / WEXITSTATUS, which Swift cannot import as macros; a child ended by a
        // signal reports 128 plus the signal, the way a shell does.
        return status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
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
