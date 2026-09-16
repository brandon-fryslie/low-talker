import Foundation
import WhisperKit

/// The on-disk home of engine models: one directory laid out the way the Hugging
/// Face hub lays out its cache, so WhisperKit's downloader and tokenizer loader
/// find their files without being told twice where they are.
///
/// [LAW:one-source-of-truth] "Is the model here and whole?" has one answer: the
/// manifests the store wrote after each part last arrived complete, one for the
/// weights and one for the tokenizer they decode with. The hub's own sidecar files
/// only record which commit a file came from; a manifest records what arrived, and
/// proves the *set* is complete, which the sidecars cannot, since a download stopped
/// between files leaves no trace of the files it never started.
public struct ModelStore: Sendable {
    /// The hub root. A model lives at `models/<org>/<repo>/<variant>` beneath it and
    /// its tokenizer at `models/openai/<whisper variant>`.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/low-talker/hub`. Application Support, not
    /// Documents where WhisperKit would put it: a 632 MB cache has no business in a
    /// folder iCloud Drive may be syncing.
    public static func applicationSupport() throws -> ModelStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return ModelStore(directory: support.appending(components: "low-talker", "hub"))
    }

    /// Where the model stands on disk. Only `.installed` yields the proof a load
    /// needs; the other two are why `install` is called. Throws when the store itself
    /// cannot be examined, such as a file or folder this process may not read.
    ///
    /// [LAW:parse-dont-validate] The checkpoint. Everything past it takes an
    /// `InstalledModel` and never asks about files again.
    public func presence(of model: ModelName) throws -> Presence {
        let weights = try recording(.weights, of: model)
        let tokenizer = try recording(.tokenizer, of: model)
        switch (weights, tokenizer) {
        case (.whole(let weights), .whole):
            return .installed(InstalledModel(model: model, folder: directory.appending(path: weights.folder), hub: directory))
        case (.unrecorded, .unrecorded):
            return .missing
        default:
            return .damaged([(ModelPart.weights, weights), (.tokenizer, tokenizer)].compactMap { part, recording in
                switch recording {
                case .whole: nil
                case .unrecorded: .unrecorded(part)
                case .damaged(let damage): damage
                }
            })
        }
    }

    /// What one part's manifest says about its files.
    enum Recording {
        case whole(Manifest)
        case unrecorded
        case damaged(Damage)
    }

    func recording(_ part: ModelPart, of model: ModelName) throws -> Recording {
        let manifestURL = manifestURL(for: model, part)
        let manifest: Manifest
        do {
            manifest = try Manifest(contentsOf: manifestURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .unrecorded
        } catch let error where error is DecodingError || error is ManifestError {
            return .damaged(.manifestUnreadable(manifest: manifestURL, part: part, reason: "\(error)"))
        }
        let folder = directory.appending(path: manifest.folder)
        let faults = try manifest.faults(in: folder)
        return faults.isEmpty ? .whole(manifest) : .damaged(.files(folder: folder, faults: faults))
    }

    /// The installed model, taking whatever the store lacks from `source` first. A
    /// part already whole here is not taken again, so a damaged install costs only
    /// the damaged parts, and an installed one costs nothing. One installer at a
    /// time: a second, from any process, waits for the first.
    ///
    /// [LAW:dataflow-not-control-flow] The sequence never changes; whether a part is
    /// fetched is decided by its `Recording`, the domain's own discriminator, judged
    /// under the lock so it describes what this installer owns.
    public func install(
        _ model: ModelName,
        from source: ModelSource,
        phase: @escaping @Sendable (InstallPhase) -> Void
    ) async throws -> InstalledModel {
        try await InstallLock.holding(directory, waiting: { phase(.waitingForAnotherInstall) }) {
            let presence = try presence(of: model)
            if case .installed(let installed) = presence { return installed }
            // [LAW:single-enforcer] The hub client trusts its own sidecar once a file
            // exists and never hashes the file, so a truncated file would come back as
            // "already downloaded". The manifest is the one judge of whole; the files it
            // rejects are removed first so no source has anything to trust.
            for url in try presence.evictions {
                try FileManager.default.removeItem(at: url)
            }
            return try await OpenSource.with(source, model, beside: self, phase: phase) { source in
                let weights = try await whole(.weights, of: model) {
                    switch source {
                    case .huggingFace:
                        phase(.downloading(fractionCompleted: 0))
                        let folder = try await WhisperKit.download(variant: model.rawValue, downloadBase: directory) { phase(.downloading(fractionCompleted: $0.fractionCompleted)) }
                        // [LAW:no-silent-failure] The hub client answers cancellation by
                        // returning the folder as far as it got, without throwing. A
                        // manifest over that folder would certify a partial model as whole.
                        try Task.checkCancellation()
                        return try Manifest(recording: folder, relativeTo: directory)
                    case .store(let store):
                        phase(.copying)
                        return try copy(.weights, of: model, from: store)
                    }
                }
                let folder = directory.appending(path: weights.folder)
                _ = try await whole(.tokenizer, of: model) {
                    switch source {
                    case .huggingFace:
                        // WhisperKit fetches the tokenizer on first load, from the hub,
                        // when it is not already here; taking it now is what lets that
                        // load, and every one after, run with the network off.
                        let variant = try ModelVariant(modelConfig: folder.appending(path: "config.json"))
                        _ = try await ModelUtilities.loadTokenizer(for: variant, tokenizerFolder: directory)
                        try Task.checkCancellation()
                        return try Manifest(recording: directory.appending(components: "models", variant.tokenizerRepo), relativeTo: directory)
                    case .store(let store):
                        phase(.copying)
                        return try copy(.tokenizer, of: model, from: store)
                    }
                }
                return InstalledModel(model: model, folder: folder, hub: directory)
            }
        }
    }

    /// Writes `<directory>/<model>.zip`, the archive a published source serves: a
    /// store holding `model` alone, taken from this store, which must hold it whole.
    ///
    /// [LAW:composability] Packing is an install into an empty store and a zip of the
    /// result, so an archive holds exactly what an install certifies, manifests and
    /// all, and nothing a hub client left beside it.
    public func pack(_ model: ModelName, into directory: URL, phase: @escaping @Sendable (InstallPhase) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory, create: true)
        // [LAW:no-silent-failure] exception: a defer cannot throw, and a staging copy
        // left behind costs disk, not correctness.
        defer { try? FileManager.default.removeItem(at: scratch) }
        let staging = ModelStore(directory: scratch.appending(path: "store"))
        _ = try await staging.install(model, from: .store(self), phase: phase)
        let archive = directory.appending(path: ModelSource.archiveName(of: model))
        try Archive.pack(staging.directory, to: archive)
        return archive
    }

    /// The part's manifest, taking the part from `fetch` and recording what arrived
    /// when it is not already whole here.
    private func whole(_ part: ModelPart, of model: ModelName, fetch: () async throws -> Manifest) async throws -> Manifest {
        if case .whole(let manifest) = try recording(part, of: model) { return manifest }
        let manifest = try await fetch()
        try manifest.write(to: manifestURL(for: model, part))
        return manifest
    }

    /// Copies the files `source`'s manifest lists for the part to the same paths
    /// here, and hands back that manifest once the copies verify against it.
    ///
    /// Each file lands under a temporary name and is renamed over its place, so a
    /// tokenizer another model shares is never absent while it is replaced. Only the
    /// listed files are copied: a sidecar beside them in the source is not the model.
    private func copy(_ part: ModelPart, of model: ModelName, from source: ModelStore) throws -> Manifest {
        let manifest: Manifest
        switch try source.recording(part, of: model) {
        case .whole(let whole): manifest = whole
        case .unrecorded: throw ModelStoreError.sourceLacks(source: source.directory, model: model, part: part, reason: "not installed there")
        case .damaged(let damage): throw ModelStoreError.sourceLacks(source: source.directory, model: model, part: part, reason: damage.description)
        }
        let from = source.directory.appending(path: manifest.folder)
        let to = directory.appending(path: manifest.folder)
        for file in manifest.files {
            let destination = to.appending(path: file.path)
            let incoming = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: incoming.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try FileManager.default.copyItem(at: from.appending(path: file.path), to: incoming)
                guard rename(incoming.path, destination.path) == 0 else {
                    throw ModelStoreError.renameFailed(from: incoming, to: destination, errno: errno)
                }
            } catch {
                // A hidden name is never recorded or evicted, so a partial copy left
                // here would outlive every retry. [LAW:no-silent-failure] exception:
                // the copy's own error is the one the caller needs; a failed removal
                // of what may never have been created adds nothing to it.
                try? FileManager.default.removeItem(at: incoming)
                throw error
            }
        }
        let faults = try manifest.faults(in: to)
        guard faults.isEmpty else {
            throw ModelStoreError.sourceLacks(source: source.directory, model: model, part: part, reason: "copied, but \(faults.map(\.description).joined(separator: "; "))")
        }
        return manifest
    }

    /// `installed/<model>.json` for the weights, where every store before the
    /// tokenizer had a manifest already wrote it, and `installed/tokenizer/<model>.json`
    /// beside it. Kept per model rather than per tokenizer: a model knows its own
    /// manifests' names without reading its weights.
    private func manifestURL(for model: ModelName, _ part: ModelPart) -> URL {
        let installed = directory.appending(path: "installed")
        return switch part {
        case .weights: installed.appending(path: "\(model.rawValue).json")
        case .tokenizer: installed.appending(components: "tokenizer", "\(model.rawValue).json")
        }
    }

    /// What `install` is doing now. `waitingForAnotherInstall` is reported once,
    /// when the lock is found held; `downloading` repeats as the fraction grows.
    ///
    /// [LAW:one-source-of-truth] The words every surface shows for a phase live here,
    /// so the menu bar and the terminal cannot describe the same moment differently.
    public enum InstallPhase: Equatable, Sendable, CustomStringConvertible {
        case waitingForAnotherInstall
        case downloading(fractionCompleted: Double)
        /// A published archive has arrived and is being unzipped.
        case unpacking
        /// Files are being copied in from another store.
        case copying

        public var description: String {
            switch self {
            case .waitingForAnotherInstall: "waiting for another install"
            case .downloading(let fraction): "downloading \(Int(fraction * 100))%"
            case .unpacking: "unpacking model"
            case .copying: "copying model"
            }
        }
    }

    public enum Presence: Sendable {
        case installed(InstalledModel)
        /// Never installed here.
        case missing
        /// Some of it was installed once, but the model is no longer proven whole.
        /// Never empty.
        case damaged([Damage])

        /// The files a repair must remove before a source will provide them again.
        public var evictions: [URL] {
            get throws {
                switch self {
                case .installed, .missing: []
                case .damaged(let damages): try damages.flatMap { try $0.evictions }
                }
            }
        }
    }

    public enum Damage: Sendable, CustomStringConvertible {
        /// The manifest is on disk but does not parse, so nothing is known about the
        /// files.
        case manifestUnreadable(manifest: URL, part: ModelPart, reason: String)
        /// Files the manifest lists that are not there as recorded. Never empty.
        case files(folder: URL, faults: [Manifest.Fault])
        /// This part has no manifest while the other has one: a store written before
        /// the tokenizer had a manifest of its own reads this way.
        case unrecorded(ModelPart)

        /// A missing file is the one fault that needs no eviction: it is already what
        /// a source must fill. An unreadable manifest names no files, so no file can
        /// be trusted and no repair is offered: a manifest recorded over what a
        /// download left would certify whatever was already there.
        public var evictions: [URL] {
            get throws {
                switch self {
                case .manifestUnreadable(let manifest, let part, let reason):
                    throw ModelStoreError.manifestUnreadable(manifest: manifest, part: part, reason: reason)
                case .files(let folder, let faults):
                    faults.compactMap { fault in
                        switch fault.kind {
                        case .missing: nil
                        case .wrongSize, .notAFile: folder.appending(path: fault.path)
                        }
                    }
                case .unrecorded: []
                }
            }
        }

        public var description: String {
            switch self {
            case .manifestUnreadable(let manifest, _, let reason): "manifest \(manifest.path) unreadable: \(reason)"
            case .files(_, let faults): faults.map(\.description).joined(separator: "; ")
            case .unrecorded(let part): "the \(part) is not installed"
            }
        }
    }
}

/// One installer per store at a time, across processes: the app's launch load and
/// the CLI's `model download` share the directory, and two downloads into it would
/// evict and write the same files under each other.
///
/// [LAW:no-ambient-temporal-coupling] The store owns the order of evict, download,
/// and manifest write. A second installer waits its turn by polling the lock between
/// sleeps, so no cooperative thread is held for the minutes a download can take.
private enum InstallLock {
    static func holding<T>(_ directory: URL, waiting: () -> Void, _ body: () async throws -> T) async throws -> T {
        let lock = directory.appending(components: "installed", ".lock")
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lock.path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw ModelStoreError.lockUnavailable(lock: lock, errno: errno)
        }
        defer { close(descriptor) }
        if try !acquire(descriptor, lock: lock) {
            waiting()
            while try !acquire(descriptor, lock: lock) {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        return try await body()
    }

    /// False while another process holds the lock; any other refusal is an error.
    private static func acquire(_ descriptor: Int32, lock: URL) throws -> Bool {
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            guard errno == EWOULDBLOCK else {
                throw ModelStoreError.lockUnavailable(lock: lock, errno: errno)
            }
            return false
        }
        return true
    }
}

public enum ModelStoreError: Error, Equatable, CustomStringConvertible {
    case manifestUnreadable(manifest: URL, part: ModelPart, reason: String)
    case lockUnavailable(lock: URL, errno: Int32)
    /// A source store that does not hold the part whole, so there is nothing to take.
    case sourceLacks(source: URL, model: ModelName, part: ModelPart, reason: String)
    /// A published base answered with something other than the archive.
    case downloadRefused(url: URL, status: Int?)
    case dittoFailed(arguments: [String], status: Int32, message: String)
    case renameFailed(from: URL, to: URL, errno: Int32)

    public var description: String {
        switch self {
        case .manifestUnreadable(let manifest, let part, let reason):
            // The folder a manifest covered is named by the manifest, which is what
            // cannot be read, so the instruction names where that part lives.
            "manifest \(manifest.path) cannot be read (\(reason)); delete it and the \(part.folderDescription), then download again"
        case .lockUnavailable(let lock, let errno):
            "cannot lock \(lock.path): \(String(cString: strerror(errno)))"
        case .sourceLacks(let source, let model, let part, let reason):
            "\(source.path) cannot supply the \(part) of \(model): \(reason)"
        case .downloadRefused(let url, let status):
            "\(url.absoluteString) answered \(status.map { "HTTP \($0)" } ?? "with no HTTP status"), not the model archive"
        case .dittoFailed(let arguments, let status, let message):
            "ditto \(arguments.joined(separator: " ")) exited \(status): \(message)"
        case .renameFailed(let from, let to, let errno):
            "cannot move \(from.path) to \(to.path): \(String(cString: strerror(errno)))"
        }
    }
}

/// Proof that a model's files are all present in a store. Only `ModelStore` makes
/// one, so holding it means the check ran.
public struct InstalledModel: Sendable {
    public let model: ModelName
    /// The folder holding the `.mlmodelc` bundles and config.
    public let folder: URL
    /// The store root, where the tokenizer for this model lives or will be fetched.
    public let hub: URL

    fileprivate init(model: ModelName, folder: URL, hub: URL) {
        self.model = model
        self.folder = folder
        self.hub = hub
    }
}

/// The set of files a complete download produced, with their sizes: a snapshot of
/// what "whole" means for one model, written once and checked on every launch.
///
/// Never empty, and every path is relative and stays under whatever root it is
/// appended to: `init(recording:)` cuts its paths from real URLs beneath the root,
/// and decoding refuses any other shape, so a `Manifest` in hand cannot reach
/// outside a store or certify nothing.
public struct Manifest: Codable, Equatable, Sendable {
    /// The model folder, relative to the store root.
    public let folder: String
    public let files: [File]

    public struct File: Codable, Equatable, Sendable {
        public let path: String
        public let size: Int64

        public init(path: String, size: Int64) {
            self.path = path
            self.size = size
        }
    }

    /// Records every regular file under `folder`, in path order so two recordings of
    /// the same folder are equal. Hidden files are not the model: the hub client keeps
    /// its sidecars in a `.cache` folder inside a tokenizer repo, and a copy lands under
    /// a hidden name before it is renamed into place.
    ///
    /// [LAW:no-silent-failure] The walk stops at its first error, and that error is
    /// the result: a manifest of the files seen before a folder refused to list
    /// would certify the model without them.
    public init(recording folder: URL, relativeTo root: URL) throws {
        let rootPath = root.standardizedFileURL.path
        let folderPath = folder.standardizedFileURL.path
        guard folderPath.hasPrefix(rootPath + "/") else {
            throw ManifestError.folderOutsideRoot(folder: folder, root: root)
        }
        self.folder = String(folderPath.dropFirst(rootPath.count + 1))

        var failure: ManifestError?
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: .skipsHiddenFiles) { url, error in
            failure = .unreadableFolder(url, reason: "\(error)")
            return false
        }
        guard let enumerator else {
            throw ManifestError.unreadableFolder(folder, reason: "no enumerator")
        }
        var files: [File] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize else { continue }
            let path = url.standardizedFileURL.path
            files.append(File(path: String(path.dropFirst(folderPath.count + 1)), size: Int64(size)))
        }
        if let failure { throw failure }
        guard !files.isEmpty else { throw ManifestError.noFiles(folder: self.folder) }
        self.files = files.sorted { $0.path < $1.path }
    }

    /// [LAW:parse-dont-validate] The read-side checkpoint: the one door every decoded
    /// manifest passes through, whether from `init(contentsOf:)` or a bare decoder.
    public init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        folder = try keys.decode(String.self, forKey: .folder)
        files = try keys.decode([File].self, forKey: .files)
        for path in [folder] + files.map(\.path) where !path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy(\.isPathStep) {
            throw ManifestError.pathEscapes(path)
        }
        guard !files.isEmpty else { throw ManifestError.noFiles(folder: folder) }
    }

    private enum CodingKeys: CodingKey {
        case folder, files
    }

    public init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The listed files that are not in `folder` as files of their recorded size;
    /// empty means whole. Extra files are not damage: the hub may add sidecars, and
    /// they carry no model weight. Only a file that does not exist is a fault; any
    /// other trouble reading it is thrown, since it is not something a download repairs.
    public func faults(in folder: URL) throws -> [Fault] {
        try files.compactMap { file in
            let values: URLResourceValues
            do {
                values = try folder.appending(path: file.path).resourceValues(forKeys: [.fileSizeKey])
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return Fault(path: file.path, kind: .missing)
            }
            guard let size = values.fileSize.map(Int64.init) else {
                return Fault(path: file.path, kind: .notAFile)
            }
            return size == file.size ? nil : Fault(path: file.path, kind: .wrongSize(expected: file.size, actual: size))
        }
    }

    /// One listed file that is not what the manifest recorded.
    public struct Fault: Equatable, Sendable, CustomStringConvertible {
        public let path: String
        public let kind: Kind

        public enum Kind: Equatable, Sendable {
            case missing
            case wrongSize(expected: Int64, actual: Int64)
            /// Something with no size, such as a folder, stands where the file was.
            case notAFile
        }

        public init(path: String, kind: Kind) {
            self.path = path
            self.kind = kind
        }

        public var description: String {
            switch kind {
            case .missing: "\(path) is missing"
            case .wrongSize(let expected, let actual): "\(path) is \(actual) bytes, expected \(expected)"
            case .notAFile: "\(path) is not a file"
            }
        }
    }
}

public enum ManifestError: Error, Equatable, CustomStringConvertible {
    case folderOutsideRoot(folder: URL, root: URL)
    /// The walk over the model folder did not finish; `URL` is where it stopped.
    case unreadableFolder(URL, reason: String)
    /// A recorded path that is absolute, or has an empty, `.`, or `..` step.
    case pathEscapes(String)
    case noFiles(folder: String)

    public var description: String {
        switch self {
        case .folderOutsideRoot(let folder, let root):
            "model folder \(folder.path) is not inside the store \(root.path)"
        case .unreadableFolder(let url, let reason):
            "cannot list \(url.path): \(reason)"
        case .pathEscapes(let path):
            "manifest path \(path) would leave the store"
        case .noFiles(let folder):
            "manifest for \(folder) lists no files"
        }
    }
}
