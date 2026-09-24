import ArgumentParser
import Foundation
import KeyboardService
import Typing

/// The virtual mouse driven report by report, for measuring what input does rather than
/// for getting something clicked.
struct PointerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pointer",
        abstract: "Drive the virtual mouse report by report.",
        subcommands: [PlayCommand.self]
    )
}

/// Replays a script of raw mouse reports at fixed times through the installed helper, and
/// says when each one went out.
///
/// It exists for a harness measuring frame smoothness while input happens: a browser's
/// own automation posts wheel events it coalesces and timestamps on a clock of its own,
/// and this mouse is hardware to macOS, so its reports arrive the way a person's do. The
/// times are collected during the play and printed after it, so writing them is never
/// what makes a report late. [LAW:effects-at-boundaries]
struct PlayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "play",
        abstract: "Replay a timed script of raw mouse reports from stdin, and print when each went out.",
        discussion: """
            The script is JSON Lines on stdin. The first line is where the cursor starts, reached \
            before the clock starts: {"to":{"x":800,"y":500}}, in screen points from the top left \
            of the main display. Every line after it is one report at t_ms milliseconds from the \
            clock's start, in order:
              {"t_ms":0,"down":"left"}               a button down: left, right or middle
              {"t_ms":8.3,"move":{"dx":4,"dy":-2}}   relative motion in counts, -127 to 127, uncorrected
              {"t_ms":16.7,"wheel":{"v":-1,"h":0}}   wheel ticks, -127 to 127; v positive scrolls content up
              {"t_ms":1000,"up":true}                every button up
            A script is refused whole, before the cursor moves, if a line is malformed, t_ms goes \
            backwards or past an hour, or it ends with a button held.

            Stdout is JSON Lines: one {"report":{"index":…,"scheduled_us":…,"sent_us":…,"acked_us":…}} \
            per report, times in microseconds since the Unix epoch, then \
            {"done":{"reports":…,"start_reports":…,"late_us":{"p50":…,"p90":…,"p99":…,"max":…}}}, \
            lateness being sent minus scheduled. A late report is sent late, never skipped.

            The play stops if the app leaves the front, a report is refused, or it is interrupted: \
            every button is released, the reports that went out are printed, and no done line is.

            \(PerformExit.discussion(for: [.helperNotApproved, .driverNotActivated], success: "Exits 0 when every report went out"))
            """
    )

    @OptionGroup var target: TargetOption
    @OptionGroup var installation: FlavorOption

    @MainActor
    func run() async throws {
        let played: Played
        do {
            // Parsed before anything is raised or connected, so a script that cannot be
            // played whole moves nothing. [LAW:parse-dont-validate]
            let play = try Play.parse(String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self))
            let interrupt = Interrupt.watched()
            let helper = HelperConnection(flavor: installation.flavor)
            let app = TargetApp(bundleID: try target.app(), interrupt: interrupt)
            try await app.raise(within: .seconds(5))
            let pointer = Pointer(
                mouse: GuardedMouse(pointing: helper.mouse, queue: DeviceQueue(), interrupt: interrupt, screen: app),
                cursor: Pointer.screenCursor,
                locate: app.frame(ofRole:titled:)
            )
            // The lead covers the hop back onto the main actor after a wake, measured at 1.6
            // to 2.1 ms on this Mac. The waking clock and not the continuous one, because
            // with the same lead the continuous clock left a far longer tail: README,
            // "Replaying mouse reports on a schedule", has the runs.
            played = try await Player(pointer: pointer, clock: WakingClock(), wall: Self.epochMicroseconds, lead: .microseconds(2500)).play(play)
        } catch {
            // The reports that went out are printed even for a run that failed, so a
            // harness can see how far it got; the missing done line is what says it failed.
            try Self.emit((error as? PlayStopped)?.played ?? [])
            throw PerformExit.fail(error, flavor: installation.flavor)
        }
        try Self.emit(played.reports)
        try Self.emit(DoneLine(done: .init(reports: played.reports.count, startReports: played.startReports, lateUs: played.lateness)))
    }

    /// The wall clock, in the unit the lines are in.
    static func epochMicroseconds() -> Int64 {
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        return Int64(now.tv_sec) * 1_000_000 + Int64(now.tv_nsec) / 1000
    }

    private static let encoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static func emit(_ line: some Encodable) throws {
        print(String(decoding: try encoder.encode(line), as: UTF8.self))
    }

    /// A line per report, numbered by its place in the script.
    private static func emit(_ reports: [Played.Report]) throws {
        for (index, report) in reports.enumerated() {
            try emit(ReportLine(report: .init(index: index, scheduledUs: report.scheduled, sentUs: report.sent, ackedUs: report.acked)))
        }
    }

    private struct ReportLine: Encodable {
        let report: Times

        struct Times: Encodable {
            let index: Int
            let scheduledUs: Int64
            let sentUs: Int64
            let ackedUs: Int64
        }
    }

    private struct DoneLine: Encodable {
        let done: Done

        struct Done: Encodable {
            let reports: Int
            let startReports: Int
            let lateUs: Lateness
        }
    }
}
