import Foundation

/// What the app runs on, after every reading of its config file so far.
///
/// [LAW:types-are-the-program] A refused save is not an absence of config: it is the config
/// already running, still in force, and the reason the new one was turned away. There is
/// deliberately no case meaning "fell back to the defaults", so that outcome cannot be
/// reported because it cannot be reached. Deleting the file is `adopted(.default)`, said by
/// `Config.load`, the one place allowed to say it.
public enum RunningConfig: Equatable, Sendable, CustomStringConvertible {
    /// The file's latest reading, and what the app runs on.
    case adopted(Config)
    /// The latest save was refused. The config named is the one that was already running,
    /// and it goes on running.
    ///
    /// [LAW:no-silent-failure] Replacing a working config with the defaults because a save
    /// was half-written is the failure the parser exists to prevent, and a reload mid-edit
    /// is where it would be easiest to commit.
    case kept(Config, because: ConfigError)
    /// Every reading since launch was refused, so there is no config to run on.
    case refused(ConfigError)

    /// What the app runs on after the first reading, at launch, which has nothing before it
    /// to keep.
    public init(reading: Result<Config, ConfigError>) {
        switch reading {
        case .success(let config): self = .adopted(config)
        case .failure(let error): self = .refused(error)
        }
    }

    /// The config the app runs on, or why there is none.
    public var config: Result<Config, ConfigError> {
        switch self {
        case .adopted(let config), .kept(let config, _): .success(config)
        case .refused(let error): .failure(error)
        }
    }

    /// Why the latest save was not taken up, while one was not.
    public var refusal: ConfigError? {
        switch self {
        case .adopted: nil
        case .kept(_, let error), .refused(let error): error
        }
    }

    /// What the app runs on when the file reads back like this - or nothing, when this
    /// reading says exactly what the last one said.
    ///
    /// [LAW:effects-at-boundaries] The whole of what a reload decides, with no file and no
    /// clock in it. Saying nothing is what makes the rest mean something: one save arrives as
    /// several changes, and a reader told about all of them would learn nothing from any.
    /// What is suppressed is a repeated answer, never a change: a file that comes back to
    /// what it said before a refusal lifts that refusal, and is reported.
    public func next(reading: Result<Config, ConfigError>) -> RunningConfig? {
        let next: RunningConfig = switch (reading, config) {
        case (.success(let config), _): .adopted(config)
        case (.failure(let error), .success(let running)): .kept(running, because: error)
        case (.failure(let error), .failure): .refused(error)
        }
        return next == self ? nil : next
    }

    /// In the words the menu says it after "Config:", and the log beside it.
    public var description: String {
        switch self {
        case .adopted: "running on the file as last saved"
        case .kept(_, let error): "the last save was refused, so the config before it still runs: \(error)"
        case .refused(let error): "it cannot be read, so nothing runs on it: \(error)"
        }
    }

    /// Every change to what the app runs on, from `running` on, as the file at `url` is
    /// saved, until the consuming task stops.
    ///
    /// [LAW:no-ambient-temporal-coupling] `running` was read before this stream existed, so
    /// a save that landed in between would be missed by the watch. Reading once after the
    /// watch is up and before its first tick closes that window by construction.
    public static func reloads(of url: URL = Config.fileURL, after running: RunningConfig) -> AsyncStream<RunningConfig> {
        // The default unbounded buffer, unlike the ticks underneath, which keep only the
        // newest: a tick repeated says the same thing twice, two reloads never do.
        AsyncStream { continuation in
            let task = Task {
                var last = running
                let ticks = DirectoryChanges.ticks(under: DirectoryChanges.nearestExistingDirectory(above: url))

                func read() {
                    guard let next = last.next(reading: Result { () throws(ConfigError) in try Config.load(url) }) else { return }
                    last = next
                    continuation.yield(next)
                }

                read()
                for await _ in ticks { read() }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
