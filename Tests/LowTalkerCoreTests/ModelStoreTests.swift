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

    @Test func untouchedFolderHasNoFaults() throws {
        let scratch = try Scratch(files: Self.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        #expect(manifest.faults(in: scratch.folder).isEmpty)
    }

    /// Extra files are not damage: the hub adds sidecars of its own.
    @Test func extraFilesAreNotFaults() throws {
        let scratch = try Scratch(files: Self.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        try "sidecar".write(to: scratch.folder.appending(path: "extra.metadata"), atomically: true, encoding: .utf8)
        #expect(manifest.faults(in: scratch.folder).isEmpty)
    }

    @Test func missingFileIsAFault() throws {
        let scratch = try Scratch(files: Self.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        try FileManager.default.removeItem(at: scratch.folder.appending(path: "AudioEncoder.mlmodelc/weights/weight.bin"))
        #expect(manifest.faults(in: scratch.folder) == [.init(path: "AudioEncoder.mlmodelc/weights/weight.bin", kind: .missing)])
    }

    /// A download that stopped mid-file leaves a short file behind; the size is the
    /// tell.
    @Test func truncatedFileIsAFault() throws {
        let scratch = try Scratch(files: Self.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        try "0123".write(to: scratch.folder.appending(path: "AudioEncoder.mlmodelc/weights/weight.bin"), atomically: true, encoding: .utf8)
        #expect(manifest.faults(in: scratch.folder) == [.init(path: "AudioEncoder.mlmodelc/weights/weight.bin", kind: .wrongSize(expected: 10, actual: 4))])
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
        let presence = store.presence(of: "test")
        guard case .damaged(.files(_, let faults)) = presence else {
            Issue.record("a manifest naming a missing file must count as damaged")
            return
        }
        #expect(faults == [.init(path: "config.json", kind: .missing)])
        #expect(try presence.evictions.isEmpty, "a file that is already gone needs no eviction")
    }

    /// The hub client never re-fetches a file that exists, so a repair must start by
    /// removing the files the manifest rejects.
    @Test func truncatedFileIsEvictedByARepair() throws {
        let scratch = try Scratch(files: Self.files)
        let store = ModelStore(directory: scratch.root)
        try Manifest(recording: scratch.folder, relativeTo: scratch.root).write(to: scratch.root.appending(components: "installed", "test.json"))
        try "{".write(to: scratch.folder.appending(path: "config.json"), atomically: true, encoding: .utf8)
        #expect(try store.presence(of: "test").evictions.map(\.standardizedFileURL) == [scratch.folder.appending(path: "config.json").standardizedFileURL])
    }

    @Test func storeWithAnUnreadableManifestIsDamaged() throws {
        let scratch = try Scratch(files: Self.files)
        let url = try scratch.writeManifest("not json")
        let presence = ModelStore(directory: scratch.root).presence(of: "test")
        guard case .damaged(.manifestUnreadable(let manifest, _)) = presence else {
            Issue.record("a corrupt manifest must count as damaged, not missing")
            return
        }
        #expect(manifest == url)
        #expect(throws: ModelStoreError.self, "with no manifest to name faults, no repair is offered") {
            try presence.evictions
        }
    }

    /// A repair over an unreadable manifest would certify whatever is on disk, so
    /// the refusal comes before any download.
    @Test func installRefusesToRepairAnUnreadableManifest() async throws {
        let scratch = try Scratch(files: Self.files)
        let url = try scratch.writeManifest("not json")
        await #expect {
            try await ModelStore(directory: scratch.root).install("test") { _ in }
        } throws: { error in
            guard case ModelStoreError.manifestUnreadable(let manifest, _) = error else { return false }
            return manifest == url
        }
    }

    /// The manifest is the only path the store follows blindly, so a manifest that
    /// points outside the store is refused as unreadable rather than followed.
    @Test func manifestPointingOutsideTheStoreIsRefused() throws {
        let scratch = try Scratch(files: Self.files)
        let url = try scratch.writeManifest(#"{"folder": "../../etc", "files": []}"#)
        #expect(throws: ManifestError.pathEscapes("../../etc")) {
            try Manifest(contentsOf: url)
        }
        guard case .damaged(.manifestUnreadable) = ModelStore(directory: scratch.root).presence(of: "test") else {
            Issue.record("a manifest that escapes the store must count as damaged")
            return
        }
    }

    @Test(arguments: ["a/b", "..", ".", "", "/x"])
    func modelNameRefusesAnythingButOnePathStep(raw: String) {
        #expect(ModelName(rawValue: raw) == nil)
    }

    @Test func modelNameAcceptsAFolderName() {
        #expect(ModelName(rawValue: "base.en")?.rawValue == "base.en")
    }

    /// The app's launch load and the CLI's `model download` share one store.
    @Test func installRefusesWhileAnotherInstallerHoldsTheLock() async throws {
        let scratch = try Scratch(files: Self.files)
        let lock = scratch.root.appending(components: "installed", ".lock")
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lock.path, O_RDONLY | O_CREAT, 0o644)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        try #require(flock(descriptor, LOCK_EX) == 0)
        await #expect(throws: ModelStoreError.installInProgress(lock: lock)) {
            try await ModelStore(directory: scratch.root).install("test") { _ in }
        }
    }
}

extension ModelStoreTests.Scratch {
    /// Puts `contents` where the store expects the manifest for model `test`.
    func writeManifest(_ contents: String) throws -> URL {
        let url = root.appending(components: "installed", "test.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
