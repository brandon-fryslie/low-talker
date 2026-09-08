import Foundation
@testable import LowTalkerCore
import Testing

/// When the watch speaks, rather than what it says.
///
/// [LAW:decomposition] The suites that read configs out of a watch cannot get at this: a
/// reading shows what the filesystem held at the moment it was taken and never how long
/// the watch waited before taking it. So the delay is asserted here, on the type that
/// owns it.
@Suite struct DirectoryChangesTests {
    /// A change waits out the latency before it is reported.
    ///
    /// This is what leaving `kFSEventStreamCreateFlagNoDefer` off buys. A save that
    /// unlinks the file before writing the new one is two changes a few milliseconds
    /// apart, and holding the first back until the batch has settled is the only reason
    /// it reads as one save rather than as a deletion followed by a creation.
    ///
    /// [LAW:no-ambient-temporal-coupling] A floor is the one timing claim a loaded
    /// machine cannot break. A stall, a busy scheduler, a slow disk can each only push
    /// the tick *later*, and what is asserted is that it did not come *sooner* - which is
    /// why the clock is read before the write, where every hazard that follows lands
    /// inside the measured span instead of shortening it.
    ///
    /// Half the latency and not all of it, so that a coalescing timer firing a hair early
    /// is not a failure. Measured on this Mac, that flag coming back puts the tick a few
    /// milliseconds out - nowhere near even the half - so the margin gives up nothing
    /// this is here to catch.
    @Test(.timeLimit(.minutes(1)))
    func aChangeIsNotReportedBeforeTheLatencyHasRun() async throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "low-talker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var ticks = DirectoryChanges.ticks(under: directory).makeAsyncIterator()
        let before = ContinuousClock.now
        try "a change".write(to: directory.appending(path: "note.txt"), atomically: true, encoding: .utf8)

        try #require(await ticks.next())
        #expect(ContinuousClock.now - before >= .seconds(DirectoryChanges.latency / 2))
    }
}
