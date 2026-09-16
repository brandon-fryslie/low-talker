import Foundation
import LowTalkerCore
import Synchronization
import Testing

/// What "installed" means, exercised on a scratch directory with small files in
/// place of model weights. The download itself needs the network and 632 MB, so it
/// is exercised by `lowtalker model download` on a Mac, not here.
@Suite struct ModelStoreTests {
    /// A store root with a model folder and a tokenizer folder inside it, deleted when
    /// the test ends.
    struct Scratch: ~Copyable {
        let root: URL
        let folder: URL
        let tokenizer: URL

        init(files: [String: String], tokenizer tokenizerFiles: [String: String] = ModelStoreTests.tokenizerFiles) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "ModelStoreTests-\(UUID().uuidString)")
            folder = root.appending(components: "models", "argmaxinc", "whisperkit-coreml", "openai_whisper-test")
            tokenizer = root.appending(components: "models", "openai", "whisper-test")
            for (base, files) in [(folder, files), (tokenizer, tokenizerFiles)] {
                for (path, contents) in files {
                    let url = base.appending(path: path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try contents.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }

        /// Writes both manifests over what is on disk, as a finished install would.
        func record() throws {
            try Manifest(recording: folder, relativeTo: root).write(to: manifestURL)
            try Manifest(recording: tokenizer, relativeTo: root).write(to: tokenizerManifestURL)
        }

        /// Puts `contents` where the store expects the manifest for model `test`.
        func writeManifest(_ contents: String) throws -> URL {
            let url = manifestURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        var manifestURL: URL { root.appending(components: "installed", "test.json") }
        var tokenizerManifestURL: URL { root.appending(components: "installed", "tokenizer", "test.json") }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }
    }

    static let tokenizerFiles = [
        "tokenizer.json": "{\"model\": {}}",
        "tokenizer_config.json": "{}",
    ]

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

    /// The hub client's sidecars sit inside a tokenizer's folder; they describe a
    /// download, not the model, and a manifest listing them would travel into every
    /// archive packed from it.
    @Test func recordingLeavesOutHiddenFiles() throws {
        let scratch = try Scratch(files: ["tokenizer.json": "{}", ".cache/huggingface/download/tokenizer.json.metadata": "etag"])
        #expect(try Manifest(recording: scratch.folder, relativeTo: scratch.root).files == [.init(path: "tokenizer.json", size: 2)])
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
        try scratch.record()
        let empty = scratch.folder.appending(path: "empty.txt")
        try FileManager.default.removeItem(at: empty)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let presence = try store.presence(of: "test")
        guard case .damaged(let damages) = presence, case .files(_, let faults) = damages.first, damages.count == 1 else {
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
        #expect("\(WhisperKitTranscriber.LoadPhase.installing(.unpacking))" == "unpacking model")
        #expect("\(WhisperKitTranscriber.LoadPhase.installing(.copying))" == "copying model")
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
        try scratch.record()
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
        try scratch.record()
        try FileManager.default.removeItem(at: scratch.folder.appending(path: "config.json"))
        let presence = try store.presence(of: "test")
        guard case .damaged(let damages) = presence, case .files(_, let faults) = damages.first, damages.count == 1 else {
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
        try scratch.record()
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
        try scratch.record()
        try "{".write(to: scratch.folder.appending(path: "config.json"), atomically: true, encoding: .utf8)
        #expect(try store.presence(of: "test").evictions.map(\.standardizedFileURL) == [scratch.folder.appending(path: "config.json").standardizedFileURL])
    }

    @Test func storeWithAnUnreadableManifestIsDamaged() throws {
        let scratch = try Scratch(files: Self.files)
        let url = try scratch.writeManifest("not json")
        let presence = try ModelStore(directory: scratch.root).presence(of: "test")
        guard case .damaged(let damages) = presence, case .manifestUnreadable(let manifest, .weights, _) = damages.first else {
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
        try scratch.record()
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
            try await ModelStore(directory: scratch.root).install("test", from: .huggingFace) { _ in }
        } throws: { error in
            guard case ModelStoreError.manifestUnreadable(let manifest, .weights, _) = error else { return false }
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
        guard case .damaged(let damages) = try ModelStore(directory: scratch.root).presence(of: "test"), case .manifestUnreadable = damages.first else {
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
        try scratch.record()
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
            return try await store.install("test", from: .huggingFace) { report.yield($0) }
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
        try scratch.record()
        let phases = Mutex<[ModelStore.InstallPhase]>([])
        let installed = try await ModelStore(directory: scratch.root).install("test", from: .huggingFace) { phase in phases.withLock { $0.append(phase) } }
        #expect(installed.folder.standardizedFileURL == scratch.folder.standardizedFileURL)
        #expect(phases.withLock { $0 }.isEmpty)
    }

    /// A store written before the tokenizer had a manifest has whole weights and no
    /// record of the tokenizer: it is not installed, and nothing in it is evicted,
    /// since the repair only has to record a tokenizer the hub folder already holds.
    @Test func storeWithWeightsButNoTokenizerManifestIsDamagedWithNothingToEvict() throws {
        let scratch = try Scratch(files: Self.files)
        try Manifest(recording: scratch.folder, relativeTo: scratch.root).write(to: scratch.manifestURL)
        let presence = try ModelStore(directory: scratch.root).presence(of: "test")
        guard case .damaged(let damages) = presence, case .unrecorded(.tokenizer) = damages.first, damages.count == 1 else {
            Issue.record("weights without a tokenizer must not count as installed")
            return
        }
        #expect(try presence.evictions.isEmpty)
        #expect("\(damages[0])" == "the tokenizer is not installed")
    }

    /// Both parts are judged, so a damaged tokenizer is evicted in the same repair as
    /// damaged weights.
    @Test func damageInBothPartsIsReportedAndEvictedTogether() throws {
        let scratch = try Scratch(files: Self.files)
        try scratch.record()
        try "{".write(to: scratch.folder.appending(path: "config.json"), atomically: true, encoding: .utf8)
        try "{".write(to: scratch.tokenizer.appending(path: "tokenizer.json"), atomically: true, encoding: .utf8)
        let presence = try ModelStore(directory: scratch.root).presence(of: "test")
        #expect(try presence.evictions.map(\.standardizedFileURL) == [
            scratch.folder.appending(path: "config.json").standardizedFileURL,
            scratch.tokenizer.appending(path: "tokenizer.json").standardizedFileURL,
        ])
    }

    /// Another store is a source: both parts arrive at the same paths with their
    /// manifests, and a sidecar beside the files in the source stays behind.
    @Test func installFromAStoreCopiesBothPartsAndTheirManifests() async throws {
        let source = try Scratch(files: Self.files)
        try source.record()
        try "sidecar".write(to: source.folder.appending(path: "extra.metadata"), atomically: true, encoding: .utf8)
        let destination = try Scratch(files: [:], tokenizer: [:])
        let store = ModelStore(directory: destination.root)
        let phases = Mutex<[ModelStore.InstallPhase]>([])
        let installed = try await store.install("test", from: .store(ModelStore(directory: source.root))) { phase in phases.withLock { $0.append(phase) } }
        #expect(installed.folder.standardizedFileURL == destination.folder.standardizedFileURL)
        guard case .installed = try store.presence(of: "test") else {
            Issue.record("a copied model must read as installed")
            return
        }
        #expect(try Manifest(contentsOf: destination.manifestURL) == Manifest(contentsOf: source.manifestURL))
        #expect(try Manifest(contentsOf: destination.tokenizerManifestURL) == Manifest(contentsOf: source.tokenizerManifestURL))
        #expect(!FileManager.default.fileExists(atPath: destination.folder.appending(path: "extra.metadata").path))
        #expect(phases.withLock { $0 } == [.copying, .copying])
    }

    /// A repair from a store replaces only what the destination lacks: a whole part
    /// is not copied again.
    @Test func installFromAStoreRepairsOnlyTheDamagedPart() async throws {
        let source = try Scratch(files: Self.files)
        try source.record()
        let destination = try Scratch(files: Self.files)
        try destination.record()
        try "0123".write(to: destination.folder.appending(path: "AudioEncoder.mlmodelc/weights/weight.bin"), atomically: true, encoding: .utf8)
        let phases = Mutex<[ModelStore.InstallPhase]>([])
        let store = ModelStore(directory: destination.root)
        _ = try await store.install("test", from: .store(ModelStore(directory: source.root))) { phase in phases.withLock { $0.append(phase) } }
        #expect(try Data(contentsOf: destination.folder.appending(path: "AudioEncoder.mlmodelc/weights/weight.bin")) == Data("0123456789".utf8))
        #expect(phases.withLock { $0 } == [.copying])
    }

    /// A source that does not hold the model whole has nothing to give, and says
    /// which part and why rather than copying what it has.
    @Test func installFromAStoreWithoutTheTokenizerIsRefused() async throws {
        let source = try Scratch(files: Self.files)
        try Manifest(recording: source.folder, relativeTo: source.root).write(to: source.manifestURL)
        let destination = try Scratch(files: [:], tokenizer: [:])
        await #expect(throws: ModelStoreError.sourceLacks(source: source.root, model: "test", part: .tokenizer, reason: "not installed there")) {
            try await ModelStore(directory: destination.root).install("test", from: .store(ModelStore(directory: source.root))) { _ in }
        }
    }

    /// The archive a published base serves unpacks into a store that holds the model
    /// installed, and holds nothing the source's manifests do not list.
    @Test func packedArchiveUnpacksIntoAStoreHoldingTheModel() async throws {
        let source = try Scratch(files: Self.files)
        try source.record()
        try "sidecar".write(to: source.folder.appending(path: "extra.metadata"), atomically: true, encoding: .utf8)
        let out = try Scratch(files: [:], tokenizer: [:])
        let archive = try await ModelStore(directory: source.root).pack("test", into: out.root) { _ in }
        #expect(archive.lastPathComponent == "test.zip")
        let unpacked = out.root.appending(path: "unpacked")
        let ditto = try Process.run(URL(filePath: "/usr/bin/ditto"), arguments: ["-x", "-k", archive.path, unpacked.path])
        ditto.waitUntilExit()
        try #require(ditto.terminationStatus == 0)
        guard case .installed = try ModelStore(directory: unpacked).presence(of: "test") else {
            Issue.record("a packed archive must unpack into an installed store")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: unpacked.appending(components: "models", "argmaxinc", "whisperkit-coreml", "openai_whisper-test", "extra.metadata").path))
    }

    /// The repair instruction names the folder the unreadable manifest covered, so a
    /// corrupt tokenizer manifest never sends anyone to delete healthy weights.
    @Test func unreadableTokenizerManifestNamesTheTokenizerFolder() async throws {
        let scratch = try Scratch(files: Self.files)
        try scratch.record()
        try "not json".write(to: scratch.tokenizerManifestURL, atomically: true, encoding: .utf8)
        await #expect {
            try await ModelStore(directory: scratch.root).install("test", from: .huggingFace) { _ in }
        } throws: { error in
            guard case ModelStoreError.manifestUnreadable(_, .tokenizer, _) = error else { return false }
            return "\(error)".contains("tokenizer's folder under models/openai")
        }
    }

    /// A copy that fails part way leaves no hidden partial file behind, since nothing
    /// records or evicts a hidden name and every retry would add another.
    @Test func failedCopyLeavesNoPartialFile() async throws {
        let source = try Scratch(files: Self.files)
        try source.record()
        let unreadable = source.folder.appending(path: "config.json")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
        let destination = try Scratch(files: [:], tokenizer: [:])
        await #expect(throws: (any Error).self) {
            try await ModelStore(directory: destination.root).install("test", from: .store(ModelStore(directory: source.root))) { _ in }
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: destination.folder.path)
        #expect(!left.contains { $0.hasPrefix(".config.json.") })
    }
}
