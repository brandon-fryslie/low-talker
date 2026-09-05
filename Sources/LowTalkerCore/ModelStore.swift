import Foundation
import WhisperKit

/// The on-disk home of engine models: one directory laid out the way the Hugging
/// Face hub lays out its cache, so WhisperKit's downloader and tokenizer loader
/// find their files without being told twice where they are.
///
/// [LAW:one-source-of-truth] "Is the model here and whole?" has one answer: the
/// manifest the store wrote after the last complete download. The hub's own sidecar
/// files only record which commit a file came from; the manifest records what
/// arrived, and proves the *set* is complete, which the sidecars cannot, since a
/// download stopped between files leaves no trace of the files it never started.
public struct ModelStore: Sendable {
    /// The hub root. A model lives at `models/<org>/<repo>/<variant>` beneath it and
    /// its tokenizer at `models/openai/<whisper variant>`.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/low-talker/hub`. Application Support, not
    /// Documents where WhisperKit would put it: a 626 MB cache has no business in a
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
        let manifestURL = manifestURL(for: model)
        let manifest: Manifest
        do {
            manifest = try Manifest(contentsOf: manifestURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch let error where error is DecodingError || error is ManifestError {
            return .damaged(.manifestUnreadable(manifest: manifestURL, reason: "\(error)"))
        }
        let folder = directory.appending(path: manifest.folder)
        let faults = try manifest.faults(in: folder)
        guard faults.isEmpty else {
            return .damaged(.files(folder: folder, faults: faults))
        }
        return .installed(InstalledModel(model: model, folder: folder, hub: directory))
    }

    /// The installed model, downloading whatever the store lacks first. Files already
    /// here are not fetched again, so a damaged install costs only the damaged parts,
    /// and an installed one costs nothing. One installer at a time: a second, from
    /// any process, waits for the first.
    ///
    /// [LAW:dataflow-not-control-flow] The sequence never changes; whether the
    /// download runs is decided by the store's `Presence` value, the domain's own
    /// discriminator, judged under the lock so it describes what this installer owns.
    public func install(
        _ model: ModelName,
        phase: @escaping @Sendable (InstallPhase) -> Void
    ) async throws -> InstalledModel {
        try await InstallLock.holding(directory, waiting: { phase(.waitingForAnotherInstall) }) {
            let presence = try presence(of: model)
            if case .installed(let installed) = presence { return installed }
            // [LAW:single-enforcer] The hub client trusts its own sidecar once a file
            // exists and never hashes the file, so a truncated file would come back as
            // "already downloaded". The manifest is the one judge of whole; the files it
            // rejects are removed first so the client has nothing to trust.
            for url in try presence.evictions {
                try FileManager.default.removeItem(at: url)
            }
            phase(.downloading(fractionCompleted: 0))
            let folder = try await WhisperKit.download(variant: model.rawValue, downloadBase: directory) { phase(.downloading(fractionCompleted: $0.fractionCompleted)) }
            // [LAW:no-silent-failure] The hub client answers cancellation by returning
            // the folder as far as it got, without throwing. A manifest over that folder
            // would certify a partial model as whole.
            try Task.checkCancellation()
            let manifest = try Manifest(recording: folder, relativeTo: directory)
            try manifest.write(to: manifestURL(for: model))
            return InstalledModel(model: model, folder: folder, hub: directory)
        }
    }

    private func manifestURL(for model: ModelName) -> URL {
        directory.appending(components: "installed", "\(model.rawValue).json")
    }

    /// What `install` is doing now. `waitingForAnotherInstall` is reported once,
    /// when the lock is found held; `downloading` repeats as the fraction grows.
    ///
    /// [LAW:one-source-of-truth] The words every surface shows for a phase live here,
    /// so the menu bar and the terminal cannot describe the same moment differently.
    public enum InstallPhase: Equatable, Sendable, CustomStringConvertible {
        case waitingForAnotherInstall
        case downloading(fractionCompleted: Double)

        public var description: String {
            switch self {
            case .waitingForAnotherInstall: "waiting for another install"
            case .downloading(let fraction): "downloading \(Int(fraction * 100))%"
            }
        }
    }

    public enum Presence: Sendable {
        case installed(InstalledModel)
        /// Never downloaded here.
        case missing
        /// Downloaded once, but no longer proven whole.
        case damaged(Damage)

        /// The files a repair must remove before the hub client will fetch them again.
        public var evictions: [URL] {
            get throws {
                switch self {
                case .installed, .missing: []
                case .damaged(let damage): try damage.evictions
                }
            }
        }
    }

    public enum Damage: Sendable, CustomStringConvertible {
        /// The manifest is on disk but does not parse, so nothing is known about the
        /// files.
        case manifestUnreadable(manifest: URL, reason: String)
        /// Files the manifest lists that are not there as recorded. Never empty.
        case files(folder: URL, faults: [Manifest.Fault])

        /// A missing file is the one fault that needs no eviction: it is already what
        /// the client must see. An unreadable manifest names no files, so no file can
        /// be trusted and no repair is offered: a manifest recorded over what a
        /// download left would certify whatever was already there.
        public var evictions: [URL] {
            get throws {
                switch self {
                case .manifestUnreadable(let manifest, let reason):
                    throw ModelStoreError.manifestUnreadable(manifest: manifest, reason: reason)
                case .files(let folder, let faults):
                    faults.compactMap { fault in
                        switch fault.kind {
                        case .missing: nil
                        case .wrongSize, .notAFile: folder.appending(path: fault.path)
                        }
                    }
                }
            }
        }

        public var description: String {
            switch self {
            case .manifestUnreadable(let manifest, let reason): "manifest \(manifest.path) unreadable: \(reason)"
            case .files(_, let faults): faults.map(\.description).joined(separator: "; ")
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
    case manifestUnreadable(manifest: URL, reason: String)
    case lockUnavailable(lock: URL, errno: Int32)

    public var description: String {
        switch self {
        case .manifestUnreadable(let manifest, let reason):
            "manifest \(manifest.path) cannot be read (\(reason)); delete it and the model's folder under models, beside installed, then download again"
        case .lockUnavailable(let lock, let errno):
            "cannot lock \(lock.path): \(String(cString: strerror(errno)))"
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
    /// the same folder are equal.
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
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) { url, error in
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
