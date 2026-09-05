import ArgumentParser
import Foundation
import LowTalkerCore

/// The CLI is how the pipeline is exercised without the hotkey. Every stage that
/// lands in LowTalkerCore gets a subcommand here before it gets wired into the app.
@main
struct LowTalker: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lowtalker",
        abstract: "Exercise the low-talker pipeline without the hotkey.",
        subcommands: [Info.self]
    )
}

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Describe an audio file as the pipeline sees it: 16 kHz mono."
    )

    @Argument(help: "An audio file AVFoundation can read (wav, aiff, m4a, ...).", transform: URL.init(fileURLWithPath:))
    var file: URL

    func run() throws {
        let clip = try AudioClip(contentsOf: file)
        print("samples: \(clip.samples.count)")
        print("duration: \(clip.duration) s")
        print("peak: \(clip.peak)")
    }
}
