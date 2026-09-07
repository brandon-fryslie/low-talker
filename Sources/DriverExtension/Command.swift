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
        try process.run()
        // Both pipes are drained before the wait. A process whose pipe fills blocks in
        // write and never exits, so a wait taken first would be a wait on a full buffer -
        // and `systemextensionsctl list` on a Mac with fourteen extensions is well past
        // the point where that stops being theoretical.
        let outBytes = out.fileHandleForReading.readDataToEndOfFile()
        let errBytes = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(
            status: process.terminationStatus,
            stdout: String(decoding: outBytes, as: UTF8.self),
            stderr: String(decoding: errBytes, as: UTF8.self)
        )
    }
}
