import ArgumentParser
import Foundation
import LowTalkerCore

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
