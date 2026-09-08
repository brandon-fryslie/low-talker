import Foundation

public extension Config {
    /// What one reading of the config file did to the config the app is running on.
    ///
    /// [LAW:types-are-the-program] Both cases carry a config, because after either one
    /// the app is still running on something and its caller always needs to know what.
    /// A file that was refused is not an absence of config: it is the previous config,
    /// still in force, and the reason the new one was turned away. There is deliberately
    /// no case meaning "fell back to the defaults", so that outcome cannot be reported
    /// because it cannot be reached.
    enum Reload: Equatable, Sendable {
        /// The file reads back differently now, and this is what the app runs on from
        /// here. Deleting the file is one of these: it reads back as `.noFile`, which is
        /// the defaults, said by the one place that is allowed to say it.
        case adopted(Loaded)
        /// The file was refused. The config named here is the one that was already
        /// running, and it goes on running.
        ///
        /// [LAW:no-silent-failure] Replacing a working config with the defaults because
        /// a save was half-written or mistyped is the exact failure the parser exists to
        /// prevent, and a mid-session reload is where it would be easiest to commit.
        case kept(Loaded, because: ConfigError)

        /// The config the app runs on after this, which is the question both cases exist
        /// to answer.
        public var running: Loaded {
            switch self {
            case .adopted(let loaded), .kept(let loaded, _): loaded
            }
        }
    }

    /// Every change to the config the app is running on, from the one it is running on
    /// now until the consuming task stops.
    ///
    /// The file watched is the one `loaded` came from. [LAW:one-source-of-truth] There
    /// is no path parameter here to disagree with it, and no second reading of what the
    /// config path is.
    ///
    /// A config that cannot be read at *startup* is not this function's business: it has
    /// no previous config to keep, so `load(from:)` throws it to a caller who can still
    /// refuse to start. What arrives here is a config already running, and everything
    /// after it is a reload.
    static func reloads(after loaded: Loaded) -> AsyncStream<Reload> {
        // Left at the default unbounded buffer, unlike the ticks underneath, which keep
        // only the newest. A tick repeated says the same thing twice; two reloads never
        // do, so a reader that falls behind has to fall behind rather than skip one.
        AsyncStream { continuation in
            let task = Task {
                var last = Reload.adopted(loaded)
                let ticks = DirectoryChanges.ticks(
                    under: DirectoryChanges.nearestExistingDirectory(above: loaded.url)
                )

                func read() {
                    guard let reload = last.next(reading: reading(loaded.url)) else { return }
                    last = reload
                    continuation.yield(reload)
                }

                // [LAW:no-ambient-temporal-coupling] The caller read the file before this
                // stream existed, so a save that landed in between is already missed by
                // the time the watch is installed. Reading once here, after the watch is
                // up and before the first tick, closes that window by construction rather
                // than by it being narrow.
                read()
                for await _ in ticks { read() }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// [LAW:effects-at-boundaries] The one place a reload touches the disk. Everything
    /// downstream of it is a pure function of what it returned.
    private static func reading(_ url: URL) -> Result<Loaded, ConfigError> {
        do { return .success(try load(from: url)) } catch { return .failure(error) }
    }
}

public extension Config.Reload {
    /// What the running config becomes when the file reads back like this - or nothing
    /// at all, when this reading says exactly what the last one already said.
    ///
    /// [LAW:effects-at-boundaries] The whole of what a watch decides, with no file and no
    /// clock in it: a test hands it a reading rather than a filesystem.
    ///
    /// Saying nothing is what makes the rest mean something. A directory stirs for
    /// reasons that have nothing to do with this file, and one save of it arrives as
    /// several changes; a reader told about all of them would learn nothing from any of
    /// them. What is suppressed here is a repeated *answer*, never a change: a file
    /// refused twice over is one refusal that still stands, and a file that comes back to
    /// what it said before a refusal is a change, and is reported.
    func next(reading: Result<Config.Loaded, ConfigError>) -> Config.Reload? {
        let read: Config.Reload = switch reading {
        case .success(let loaded): .adopted(loaded)
        case .failure(let error): .kept(running, because: error)
        }
        return read == self ? nil : read
    }
}
