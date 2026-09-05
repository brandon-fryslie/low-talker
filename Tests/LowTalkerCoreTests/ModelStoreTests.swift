import Foundation
import LowTalkerCore
import Synchronization
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

        /// Puts `contents` where the store expects the manifest for model `test`.
        func writeManifest(_ contents: String) throws -> URL {
            let url = manifestURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        var manifestURL: URL { root.appending(components: "installed", "test.json") }

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

    /// A walk that stops early must not become a manifest of the files seen so far.
    @Test func recordingAFolderThatDoesNotExistThrows() throws {
        let scratch = try Scratch(files: [:])
        #expect(throws: ManifestError.self) {
            try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        }
    }

    @Test func recordingAnEmptyFolderThrows() throws {
        let scratch = try Scratch(files: [:])
        try FileManager.default.createDirectory(at: scratch.folder, withIntermediateDirectories: true)
        #expect(throws: ManifestError.noFiles(folder: "models/argmaxinc/whisperkit-coreml/openai_whisper-test")) {
            try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        }
    }

    @Test func manifestSurvivesTheRoundTripToDisk() throws {
        let scratch = try Scratch(files: Self.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        try manifest.write(to: scratch.manifestURL)
        #expect(try Manifest(contentsOf: scratch.manifestURL) == manifest)
    }

    @Test func untouchedFolderHasNoFaults() throws {
        let scratch = try Scratch(files: Self.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        #expect(try manifest.faults(in: scratch.folder).isEmpty)
    }

    /// Extra files are not damage: the hub adds sidecars of its own.
    @Test func extraFilesAreNotFaults() throws {
        let scratch = try Scratch(files: Self.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        try "sidecar".write(to: scratch.folder.appending(path: "extra.metadata"), atomically: true, encoding: .utf8)
        #expect(try manifest.faults(in: scratch.folder).isEmpty)
    }

    @Test func missingFileIsAFault() throws {
        let scratch = try Scratch(files: Self.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        try FileManager.default.removeItem(at: scratch.folder.appending(path: "AudioEncoder.mlmodelc/weights/weight.bin"))
        #expect(try manifest.faults(in: scratch.folder) == [.init(path: "AudioEncoder.mlmodelc/weights/weight.bin", kind: .missing)])
    }

    /// A download that stopped mid-file leaves a short file behind; the size is the
    /// tell.
    @Test func truncatedFileIsAFault() throws {
        let scratch = try Scratch(files: Self.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        try "0123".write(to: scratch.folder.appending(path: "AudioEncoder.mlmodelc/weights/weight.bin"), atomically: true, encoding: .utf8)
        #expect(try manifest.faults(in: scratch.folder) == [.init(path: "AudioEncoder.mlmodelc/weights/weight.bin", kind: .wrongSize(expected: 10, actual: 4))])
    }

    /// A folder standing where a file belongs is its own kind of fault, not a size:
    /// a 0-byte file is a legitimate recording, so no size may stand in for "none".
    /// The repair removes the folder rather than leaving the hub client to trust it.
    @Test func folderInAFilesPlaceIsAFaultTheRepairEvicts() throws {
        let scratch = try Scratch(files: Self.files.merging(["empty.txt": ""]) { _, new in new })
        let store = ModelStore(directory: scratch.root)
        try Manifest(recording: scratch.folder, relativeTo: scratch.root).write(to: scratch.manifestURL)
        let empty = scratch.folder.appending(path: "empty.txt")
        try FileManager.default.removeItem(at: empty)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let presence = try store.presence(of: "test")
        guard case .damaged(.files(_, let faults)) = presence else {
            Issue.record("a folder in a listed file's place must count as damaged")
            return
        }
        #expect(faults == [.init(path: "empty.txt", kind: .notAFile)])
        #expect(try presence.evictions.map(\.standardizedFileURL) == [empty.standardizedFileURL])
    }

    /// The menu bar and the terminal both show a phase's own words, so the words
    /// are pinned once, here.
    @Test func phasesDescribeThemselves() {
        #expect("\(WhisperKitTranscriber.LoadPhase.installing(.waitingForAnotherInstall))" == "waiting for another install")
        #expect("\(WhisperKitTranscriber.LoadPhase.installing(.downloading(fractionCompleted: 0.426)))" == "downloading 42%")
        #expect("\(WhisperKitTranscriber.LoadPhase.loading)" == "loading model")
    }

    /// A file this process may not reach is not a missing file: a download would
    /// not repair it, so the trouble is reported as itself.
    @Test func unreachableFileIsAnErrorNotAFault() throws {
        let scratch = try Scratch(files: Self.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        let weights = scratch.folder.appending(path: "AudioEncoder.mlmodelc/weights")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: weights.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: weights.path) }
        #expect(throws: CocoaError.self) {
            try manifest.faults(in: scratch.folder)
        }
    }

    @Test func storeWithoutAManifestIsMissing() throws {
        let scratch = try Scratch(files: Self.files)
        guard case .missing = try ModelStore(directory: scratch.root).presence(of: "test") else {
            Issue.record("a folder without a manifest must not count as installed")
            return
        }
    }

    @Test func storeWithAManifestThatVerifiesIsInstalled() throws {
        let scratch = try Scratch(files: Self.files)
        let store = ModelStore(directory: scratch.root)
        try Manifest(recording: scratch.folder, relativeTo: scratch.root).write(to: scratch.manifestURL)
        guard case .installed(let installed) = try store.presence(of: "test") else {
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
        try Manifest(recording: scratch.folder, relativeTo: scratch.root).write(to: scratch.manifestURL)
        try FileManager.default.removeItem(at: scratch.folder.appending(path: "config.json"))
        let presence = try store.presence(of: "test")
        guard case .damaged(.files(_, let faults)) = presence else {
            Issue.record("a manifest naming a missing file must count as damaged")
            return
        }
        #expect(faults == [.init(path: "config.json", kind: .missing)])
        #expect(try presence.evictions.isEmpty, "a file that is already gone needs no eviction")
    }

    /// A folder this process may not search is not damage a download would repair,
    /// so the store passes the trouble up instead of folding it into `.damaged`.
    @Test func storeThatCannotBeSearchedThrowsRatherThanReadingDamaged() throws {
        let scratch = try Scratch(files: Self.files)
        let store = ModelStore(directory: scratch.root)
        try Manifest(recording: scratch.folder, relativeTo: scratch.root).write(to: scratch.manifestURL)
        let weights = scratch.folder.appending(path: "AudioEncoder.mlmodelc/weights")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: weights.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: weights.path) }
        #expect(throws: CocoaError.self) {
            try store.presence(of: "test")
        }
    }

    /// The hub client never re-fetches a file that exists, so a repair must start by
    /// removing the files the manifest rejects.
    @Test func truncatedFileIsEvictedByARepair() throws {
        let scratch = try Scratch(files: Self.files)
        let store = ModelStore(directory: scratch.root)
        try Manifest(recording: scratch.folder, relativeTo: scratch.root).write(to: scratch.manifestURL)
        try "{".write(to: scratch.folder.appending(path: "config.json"), atomically: true, encoding: .utf8)
        #expect(try store.presence(of: "test").evictions.map(\.standardizedFileURL) == [scratch.folder.appending(path: "config.json").standardizedFileURL])
    }

    @Test func storeWithAnUnreadableManifestIsDamaged() throws {
        let scratch = try Scratch(files: Self.files)
        let url = try scratch.writeManifest("not json")
        let presence = try ModelStore(directory: scratch.root).presence(of: "test")
        guard case .damaged(.manifestUnreadable(let manifest, _)) = presence else {
            Issue.record("a corrupt manifest must count as damaged, not missing")
            return
        }
        #expect(manifest == url)
        #expect(throws: ModelStoreError.self, "with no manifest to name faults, no repair is offered") {
            try presence.evictions
        }
    }

    /// A manifest this process may not read is not a corrupt one: telling the user
    /// to delete the model would be the wrong instruction, so the trouble is passed up.
    @Test func storeWhoseManifestCannotBeReadThrowsRatherThanReadingDamaged() throws {
        let scratch = try Scratch(files: Self.files)
        let store = ModelStore(directory: scratch.root)
        try Manifest(recording: scratch.folder, relativeTo: scratch.root).write(to: scratch.manifestURL)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: scratch.manifestURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: scratch.manifestURL.path) }
        #expect(throws: CocoaError.self) {
            try store.presence(of: "test")
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
        let url = try scratch.writeManifest(#"{"folder": "../../etc", "files": [{"path": "passwd", "size": 1}]}"#)
        #expect(throws: ManifestError.pathEscapes("../../etc")) {
            try Manifest(contentsOf: url)
        }
        guard case .damaged(.manifestUnreadable) = try ModelStore(directory: scratch.root).presence(of: "test") else {
            Issue.record("a manifest that escapes the store must count as damaged")
            return
        }
    }

    /// A manifest listing nothing would verify against any folder at all.
    @Test func manifestWithNoFilesIsRefused() throws {
        let scratch = try Scratch(files: Self.files)
        let url = try scratch.writeManifest(#"{"folder": "models/x", "files": []}"#)
        #expect(throws: ManifestError.noFiles(folder: "models/x")) {
            try Manifest(contentsOf: url)
        }
    }

    @Test(arguments: ["a/b", "..", ".", "", "/x"])
    func modelNameRefusesAnythingButOnePathStep(raw: String) {
        #expect(ModelName(rawValue: raw) == nil)
    }

    @Test func modelNameAcceptsAFolderName() {
        #expect(ModelName(rawValue: "base.en")?.rawValue == "base.en")
    }

    /// The app's launch load and the CLI's `model download` share one store: the
    /// second installer waits for the first, then finds its work already done.
    @Test(.timeLimit(.minutes(1))) func installWaitsForAnotherInstallerAndTakesItsResult() async throws {
        let scratch = try Scratch(files: Self.files)
        try Manifest(recording: scratch.folder, relativeTo: scratch.root).write(to: scratch.manifestURL)
        let lock = scratch.root.appending(components: "installed", ".lock")
        let descriptor = open(lock.path, O_RDONLY | O_CREAT, 0o644)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        try #require(flock(descriptor, LOCK_EX) == 0)

        // [LAW:no-ambient-temporal-coupling] The install reports its phases into the
        // stream and finishes it when it returns, so the test advances on what the
        // install says, and an install that never reports the wait ends the stream.
        let (phases, report) = AsyncStream.makeStream(of: ModelStore.InstallPhase.self)
        let store = ModelStore(directory: scratch.root)
        let installing = Task {
            defer { report.finish() }
            return try await store.install("test") { report.yield($0) }
        }
        var reported = phases.makeAsyncIterator()
        try #require(await reported.next() == .waitingForAnotherInstall, "the second installer reports the wait before anything else")
        try #require(flock(descriptor, LOCK_UN) == 0)

        let installed = try await installing.value
        #expect(installed.model == "test")
        #expect(await reported.next() == nil, "an installed model is taken as found, with no download")
    }

    /// An installed model costs nothing to install again.
    @Test func installOnAnInstalledStoreReturnsItWithoutDownloading() async throws {
        let scratch = try Scratch(files: Self.files)
        try Manifest(recording: scratch.folder, relativeTo: scratch.root).write(to: scratch.manifestURL)
        let phases = Mutex<[ModelStore.InstallPhase]>([])
        let installed = try await ModelStore(directory: scratch.root).install("test") { phase in phases.withLock { $0.append(phase) } }
        #expect(installed.folder.standardizedFileURL == scratch.folder.standardizedFileURL)
        #expect(phases.withLock { $0 }.isEmpty)
    }
}
