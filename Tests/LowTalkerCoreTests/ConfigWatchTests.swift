import Flavors
import Foundation
import LowTalkerCore
import Testing

/// The config kept current with its file: what a save does to the config the app is
/// already running on, and what a save it cannot understand does not do to it.
@Suite struct ConfigWatchTests {
    static func file(chord: String) -> String {
        """
        [[modes]]
        name = "dictation"
        chord = { modifiers = ["\(chord)"] }
        """
    }

    static let onRightCommand = file(chord: "rightCommand")
    static let onLeftControl = file(chord: "leftControl")
    /// TOML that stops being TOML part way through a table header.
    static let notTOML = "model = \"base.en\"\n[[modes\n"

    // MARK: - What a reading does to the running config

    // These hand `next(reading:)` a reading rather than a filesystem, so every rule
    // about what a save does is settled without a file, a watch, or a wait.

    static let somewhere = URL(filePath: "/tmp/low-talker-test/config.toml")

    /// What a save does to the running config is the same on either installation, so
    /// these all read as the release copy and say so once here. A reading is assembled
    /// through `reading(_:at:)` and `nothing(at:)` rather than case by case, so no test
    /// can pair a file with the other copy's flavor and pin an arrangement that cannot
    /// arise. [LAW:one-source-of-truth]
    static let flavor = Flavor.release

    static func config(_ toml: String) throws(ConfigError) -> Config {
        try Config(toml: toml, flavor: flavor)
    }

    /// A reading that found a file.
    static func reading(_ toml: String, at url: URL) throws -> Config.Loaded {
        .file(try config(toml), at: url, flavor: flavor)
    }

    /// A reading that found none, so the defaults apply.
    static func nothing(at url: URL) -> Config.Loaded {
        .noFile(at: url, flavor: flavor)
    }

    static func running(_ toml: String) throws -> Config.Reload {
        .adopted(try reading(toml, at: somewhere))
    }

    @Test func aReadingThatSaysWhatTheLastOneSaidIsNotReported() throws {
        let last = try Self.running(Self.onRightCommand)
        #expect(last.next(reading: .success(last.running)) == nil)
    }

    @Test func aDifferentConfigIsAdopted() throws {
        let last = try Self.running(Self.onRightCommand)
        let saved = try Self.reading(Self.onLeftControl, at: Self.somewhere)
        #expect(last.next(reading: .success(saved)) == .adopted(saved))
    }

    /// The rule this whole type exists for: a save that cannot be understood costs the
    /// author nothing, because what they were running goes on running.
    @Test func aRefusedReadingKeepsTheRunningConfigAndNamesWhy() throws {
        let last = try Self.running(Self.onRightCommand)
        let reload = last.next(reading: .failure(.noModes))
        #expect(reload == .kept(last.running, because: .noModes))
        #expect(reload?.running == last.running)
    }

    /// A refusal that still stands is not news. One save arrives as several changes, and
    /// an author told about each of them learns nothing from any.
    @Test func aFileRefusedTwiceOverIsOneRefusal() throws {
        let refused = try Self.running(Self.onRightCommand).next(reading: .failure(.noModes))
        #expect(try #require(refused).next(reading: .failure(.noModes)) == nil)
    }

    /// The case a plain "has the config changed?" would miss: the author breaks the file
    /// and then undoes the edit. The config is the one that was already running, so
    /// comparing configs alone would say nothing happened - but the refusal standing
    /// against it has been lifted, and that is worth saying.
    @Test func undoingABadSaveIsReportedEvenThoughTheConfigIsUnchanged() throws {
        let last = try Self.running(Self.onRightCommand)
        let refused = try #require(last.next(reading: .failure(.noModes)))
        #expect(refused.next(reading: .success(last.running)) == .adopted(last.running))
    }

    /// Deleting the file is a reload like any other, and it arrives as the case that
    /// means the defaults rather than as a config that happens to equal them.
    @Test func theFileDisappearingIsAdoptedAsTheDefaults() throws {
        let last = try Self.running(Self.onRightCommand)
        let gone = Self.nothing(at: Self.somewhere)
        #expect(last.next(reading: .success(gone)) == .adopted(gone))
        #expect(last.next(reading: .success(gone))?.running.config == Config.default(for: Self.flavor))
    }

    // MARK: - Against a real file

    // A real directory and a real FSEvents stream, because what these prove is that the
    // watch hears an edit at all - which no fake filesystem could establish.
    //
    // The time limit is there to fail a hung test rather than to time anything: each of
    // these waits on the stream itself, so a slow machine makes them slow and never makes
    // them wrong.

    /// A directory to write configs into, and the config path inside it. The directory is
    /// made only when `existing` says so: a config directory nobody has created yet is
    /// the state a watch has to survive, and one of these tests starts in it.
    static func scratch(existing: Bool) throws -> (directory: URL, file: URL) {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "low-talker-\(UUID().uuidString)/low-talker")
        try FileManager.default.createDirectory(
            at: existing ? directory : directory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return (directory, directory.appending(path: "config.toml"))
    }

    /// A watch on `file` that is already past the read it does when it starts.
    ///
    /// Worth the extra save in every one of these. `reloads(after:)` reads once as it
    /// comes up, to close the window between the caller's own load and the watch being
    /// installed - so a test whose only edit lands in that window proves that read
    /// happened and says nothing whatever about whether the watch hears anything. Waiting
    /// for one edit to be reported puts the watch in its loop, and every edit after it
    /// can only have been heard by FSEvents.
    static func watching(_ file: URL, settlingOn settling: String) async throws
        -> (running: Config.Loaded, reloads: AsyncStream<Config.Reload>.AsyncIterator)
    {
        var reloads = Config.reloads(after: try Config.load(file, for: Self.flavor)).makeAsyncIterator()
        try settling.write(to: file, atomically: true, encoding: .utf8)
        let settled = try #require(await reloads.next())
        #expect(settled == .adopted(try Self.reading(settling, at: file)))
        return (settled.running, reloads)
    }

    @Test(.timeLimit(.minutes(1)))
    func editingTheChordTakesEffect() async throws {
        let (directory, file) = try Self.scratch(existing: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var (_, reloads) = try await Self.watching(file, settlingOn: Self.onRightCommand)

        try Self.onLeftControl.write(to: file, atomically: true, encoding: .utf8)

        let reload = try #require(await reloads.next())
        #expect(reload == .adopted(try Self.reading(Self.onLeftControl, at: file)))
        #expect(reload.running.config.chords == [KeyChord(modifiers: .leftControl)])
    }

    /// The done-condition's other half, against a real save: a syntax error leaves the
    /// app running on the config it already had.
    @Test(.timeLimit(.minutes(1)))
    func aSyntaxErrorLeavesTheRunningConfigInPlace() async throws {
        let (directory, file) = try Self.scratch(existing: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var (started, reloads) = try await Self.watching(file, settlingOn: Self.onRightCommand)

        try Self.notTOML.write(to: file, atomically: true, encoding: .utf8)

        let reload = try #require(await reloads.next())
        #expect(reload.running == started)
        // A file that is not TOML at all still names the line reading stopped on, which
        // is the one fault a position can be had for. The wording around it is TOML++'s
        // and is not this test's to pin. [LAW:behavior-not-structure]
        guard case .kept(_, .notTOML(_, let line)) = reload else {
            Issue.record("expected .kept with a parse fault, got \(reload)")
            return
        }
        #expect(line == 2)
    }

    /// A save that changes nothing is not reported - proven by making a real change after
    /// it and finding that change, rather than the touch, at the head of the stream.
    @Test(.timeLimit(.minutes(1)))
    func aSaveThatChangesNothingIsNotReported() async throws {
        let (directory, file) = try Self.scratch(existing: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var (_, reloads) = try await Self.watching(file, settlingOn: Self.onRightCommand)

        try Self.onRightCommand.write(to: file, atomically: true, encoding: .utf8)
        try "not a config".write(to: directory.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        try Self.onLeftControl.write(to: file, atomically: true, encoding: .utf8)

        #expect(await reloads.next() == .adopted(try Self.reading(Self.onLeftControl, at: file)))
    }

    /// The config directory does not exist when the watch starts, which is where a watch
    /// installed on the file - or on a directory that is not there - hears nothing ever
    /// again.
    @Test(.timeLimit(.minutes(1)))
    func aConfigDirectoryThatDoesNotExistYetIsStillWatched() async throws {
        let (directory, file) = try Self.scratch(existing: false)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let started = try Config.load(file, for: Self.flavor)
        #expect(started == Self.nothing(at: file))

        var reloads = Config.reloads(after: started).makeAsyncIterator()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.onRightCommand.write(to: file, atomically: true, encoding: .utf8)
        #expect(await reloads.next() == .adopted(try Self.reading(Self.onRightCommand, at: file)))

        // The edit that carries the claim: the watch went up on a directory that was not
        // there, and is still hearing saves in the one that replaced it.
        try Self.onLeftControl.write(to: file, atomically: true, encoding: .utf8)
        #expect(await reloads.next() == .adopted(try Self.reading(Self.onLeftControl, at: file)))
    }

    /// The config directory is taken away under a running watch and made again - what a
    /// reinstall does, or an `rm -rf ~/.config/low-talker` followed by writing a fresh
    /// config. The watch is rooted at that directory, so a stream that did not survive it
    /// would go quiet for the rest of the process and look exactly like nobody saving.
    /// [LAW:no-silent-failure]
    ///
    /// The claim is carried by what a reload *says* rather than by when it arrives. Ticks
    /// are indistinguishable and the directory coming back raises its own, so pinning this
    /// on a tick would mean telling two of them apart by the clock - and at this layer
    /// there is nothing to tell apart: only a read of the new file can name the chord in
    /// it. The directory's absence is a real reload too, which is why the one that carries
    /// the claim is found by its content and not by its place in the queue.
    /// [LAW:behavior-not-structure]
    @Test(.timeLimit(.minutes(1)))
    func aConfigDirectoryDeletedAndMadeAgainIsStillWatched() async throws {
        let (directory, file) = try Self.scratch(existing: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var (_, reloads) = try await Self.watching(file, settlingOn: Self.onRightCommand)

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.onLeftControl.write(to: file, atomically: true, encoding: .utf8)

        let adopted = Config.Reload.adopted(try Self.reading(Self.onLeftControl, at: file))
        var reload: Config.Reload
        repeat {
            reload = try #require(await reloads.next())
        } while reload != adopted
    }

    /// Deleting the file goes back to the defaults, and says it did: the report a reader
    /// gets names an absent file rather than showing them the defaults as though someone
    /// had written them.
    @Test(.timeLimit(.minutes(1)))
    func deletingTheFileGoesBackToTheDefaults() async throws {
        let (directory, file) = try Self.scratch(existing: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var (_, reloads) = try await Self.watching(file, settlingOn: Self.onRightCommand)

        try FileManager.default.removeItem(at: file)

        let reload = try #require(await reloads.next())
        #expect(reload == .adopted(Self.nothing(at: file)))
        #expect(reload.running.config == Config.default(for: Self.flavor))
    }
}
