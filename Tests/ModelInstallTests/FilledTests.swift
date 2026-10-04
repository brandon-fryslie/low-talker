import Foundation
import LowTalkerCore
@testable import ModelInstall
import Synchronization
import TestProbes
import Testing

/// A download judged against the manifest the hub's listing made, with a stand-in for
/// the hub client that, like it, writes only the files that are not already there.
@Suite struct FilledTests {
    /// The sizes `ScratchStore.files` are, as the hub would list them.
    static func manifest(of scratch: borrowing ScratchStore) throws -> Manifest {
        try Manifest(folder: Manifest.folder(scratch.folder, relativeTo: scratch.root), files: ScratchStore.files.map { .init(path: $0.key, size: Int64($0.value.utf8.count)) })
    }

    /// Writes each of `ScratchStore.files` that is absent, and trusts any that exists.
    static func download(into folder: URL) throws {
        for (path, contents) in ScratchStore.files where !FileManager.default.fileExists(atPath: folder.appending(path: path).path) {
            try contents.write(to: folder.appending(path: path), atomically: true, encoding: .utf8)
        }
    }

    /// A store filled by copying from another cache, one file truncated before any
    /// manifest was written: the truncated file is removed, fetched again, and the
    /// part certified only once it is whole.
    @Test func truncatedFileInAPrepopulatedFolderIsTakenAgain() async throws {
        let scratch = try ScratchStore(files: ScratchStore.files.merging(["AudioEncoder.mlmodelc/weights/weight.bin": "01234"]) { _, truncated in truncated })
        let expected = try Self.manifest(of: scratch)
        let folder = scratch.folder
        let phases = Mutex<[ModelStore.InstallPhase]>([])
        let manifest = try await ModelStore(directory: scratch.root).filled(expected, phase: { phase in phases.withLock { $0.append(phase) } }) {
            try Self.download(into: folder)
        }
        #expect(manifest == expected)
        #expect(try Data(contentsOf: folder.appending(path: "AudioEncoder.mlmodelc/weights/weight.bin")) == Data("0123456789".utf8))
        #expect(phases.withLock { $0 } == [.evicting(["AudioEncoder.mlmodelc/weights/weight.bin"])])
    }

    /// A download that returns without every listed file whole fails the install
    /// rather than certifying what it left.
    @Test func downloadThatComesUpShortFailsTheInstall() async throws {
        let scratch = try ScratchStore(files: ScratchStore.files.filter { $0.key != "config.json" })
        let expected = try Self.manifest(of: scratch)
        let folder = scratch.folder
        await #expect(throws: ModelInstallError.incomplete(folder: folder, faults: [.init(path: "config.json", kind: .missing)])) {
            try await ModelStore(directory: scratch.root).filled(expected, phase: { _ in }) {}
        }
    }
}
