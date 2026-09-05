import Foundation
import LowTalkerCore
import Testing

/// What "installed" means, exercised on a scratch directory with small files in
/// place of model weights. The download itself needs the network and 626 MB, so it
/// is exercised by `lowtalker model download` on a Mac, not here.
@Suite struct ModelStoreTests {
    /// A store root with a model folder inside it, deleted when the test ends.
    struct Scratch: ~Copyable {
        let root: URL
        let folder: URL

        init(files: [String: String]) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "ModelStoreTests-\(UUID().uuidString)")
            folder = root.appending(components: "models", "argmaxinc", "whisperkit-coreml", "openai_whisper-test")
            for (path, contents) in files {
                let url = folder.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: url, atomically: true, encoding: .utf8)
            }
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }
    }

    static let files = [
        "config.json": "{}",
        "AudioEncoder.mlmodelc/model.mil": "program",
        "AudioEncoder.mlmodelc/weights/weight.bin": "0123456789",
    ]

    @Test func recordingListsEveryFileWithItsSizeInPathOrder() throws {
        let scratch = try Scratch(files: Self.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        #expect(manifest.folder == "models/argmaxinc/whisperkit-coreml/openai_whisper-test")
        #expect(manifest.files == [
            .init(path: "AudioEncoder.mlmodelc/model.mil", size: 7),
            .init(path: "AudioEncoder.mlmodelc/weights/weight.bin", size: 10),
            .init(path: "config.json", size: 2),
        ])
    }

    @Test func recordingRefusesAFolderOutsideTheRoot() throws {
        let scratch = try Scratch(files: Self.files)
        #expect(throws: ManifestError.self) {
            try Manifest(recording: scratch.folder, relativeTo: FileManager.default.temporaryDirectory.appending(path: "elsewhere"))
        }
    }

    @Test func manifestSurvivesTheRoundTripToDisk() throws {
        let scratch = try Scratch(files: Self.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        let url = scratch.root.appending(components: "installed", "test.json")
        try manifest.write(to: url)
        #expect(try Manifest(contentsOf: url) == manifest)
    }

    @Test func untouchedFolderVerifies() throws {
        let scratch = try Scratch(files: Self.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        try manifest.verify(against: scratch.folder)
    }

    /// Extra files are not damage: the hub adds sidecars of its own.
    @Test func extraFilesDoNotFailVerification() throws {
        let scratch = try Scratch(files: Self.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        try "sidecar".write(to: scratch.folder.appending(path: "extra.metadata"), atomically: true, encoding: .utf8)
        try manifest.verify(against: scratch.folder)
    }

    @Test func missingFileFailsVerification() throws {
        let scratch = try Scratch(files: Self.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        try FileManager.default.removeItem(at: scratch.folder.appending(path: "AudioEncoder.mlmodelc/weights/weight.bin"))
        #expect(throws: ManifestError.self) { try manifest.verify(against: scratch.folder) }
    }

    /// A download that stopped mid-file leaves a short file behind; the size is the
    /// tell.
    @Test func truncatedFileFailsVerification() throws {
        let scratch = try Scratch(files: Self.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        try "0123".write(to: scratch.folder.appending(path: "AudioEncoder.mlmodelc/weights/weight.bin"), atomically: true, encoding: .utf8)
        #expect(throws: ManifestError.self) { try manifest.verify(against: scratch.folder) }
    }

    @Test func storeWithoutAManifestIsMissing() throws {
        let scratch = try Scratch(files: Self.files)
        guard case .missing = ModelStore(directory: scratch.root).presence(of: "test") else {
            Issue.record("a folder without a manifest must not count as installed")
            return
        }
    }

    @Test func storeWithAManifestThatVerifiesIsInstalled() throws {
        let scratch = try Scratch(files: Self.files)
        let store = ModelStore(directory: scratch.root)
        try Manifest(recording: scratch.folder, relativeTo: scratch.root).write(to: scratch.root.appending(components: "installed", "test.json"))
        guard case .installed(let installed) = store.presence(of: "test") else {
            Issue.record("a verified manifest must count as installed")
            return
        }
        #expect(installed.model == "test")
        #expect(installed.folder.standardizedFileURL == scratch.folder.standardizedFileURL)
        #expect(installed.hub == scratch.root)
    }

    @Test func storeWithAManifestThatDoesNotVerifyIsDamaged() throws {
        let scratch = try Scratch(files: Self.files)
        let store = ModelStore(directory: scratch.root)
        try Manifest(recording: scratch.folder, relativeTo: scratch.root).write(to: scratch.root.appending(components: "installed", "test.json"))
        try FileManager.default.removeItem(at: scratch.folder.appending(path: "config.json"))
        guard case .damaged(let reason) = store.presence(of: "test") else {
            Issue.record("a manifest naming a missing file must count as damaged")
            return
        }
        #expect(reason.contains("config.json"))
    }

    @Test func storeWithAnUnreadableManifestIsDamaged() throws {
        let scratch = try Scratch(files: Self.files)
        let url = scratch.root.appending(components: "installed", "test.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        guard case .damaged = ModelStore(directory: scratch.root).presence(of: "test") else {
            Issue.record("a corrupt manifest must count as damaged, not missing")
            return
        }
    }
}
