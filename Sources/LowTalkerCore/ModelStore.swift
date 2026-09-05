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
    /// needs; the other two are the reasons `install` is called.
    ///
    /// [LAW:parse-dont-validate] The checkpoint. Everything past it takes an
    /// `InstalledModel` and never asks about files again.
    public func presence(of model: ModelName) -> Presence {
        let manifestURL = manifestURL(for: model)
        let manifest: Manifest
        do {
            manifest = try Manifest(contentsOf: manifestURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .damaged(.manifestUnreadable(manifest: manifestURL, reason: "\(error)"))
        }
        let folder = directory.appending(path: manifest.folder)
        let faults = manifest.faults(in: folder)
        guard faults.isEmpty else {
            return .damaged(.files(folder: folder, faults: faults))
        }
        return .installed(InstalledModel(model: model, folder: folder, hub: directory))
    }

    /// Downloads the model into the store, or finishes a download that stopped, then
    /// records the manifest that makes it `.installed`. Files already here are not
    /// fetched again, so calling this on a damaged install costs only the damaged
    /// parts. One installer at a time: a second, from any process, is refused.
    public func install(
        _ model: ModelName,
        progress: @escaping @Sendable (_ fractionCompleted: Double) -> Void
    ) async throws -> InstalledModel {
        try await InstallLock.holding(directory) {
            // [LAW:single-enforcer] The hub client trusts its own sidecar once a file
            // exists and never hashes the file, so a truncated file would come back as
            // "already downloaded". The manifest is the one judge of whole; the files it
            // rejects are removed first so the client has nothing to trust.
            for url in try presence(of: model).evictions {
                try FileManager.default.removeItem(at: url)
            }
            let folder = try await WhisperKit.download(variant: model.rawValue, downloadBase: directory) { progress($0.fractionCompleted) }
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
        /// Files the manifest lists that are gone or the wrong size. Never empty.
        case files(folder: URL, faults: [Manifest.Fault])

        /// A missing file is already what the client must see; only a wrong-sized
        /// one stands in the way. An unreadable manifest names no files, so no file
        /// can be trusted and no repair is offered: a manifest recorded over what a
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
                        case .wrongSize: folder.appending(path: fault.path)
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
/// and manifest write; a second installer is refused at once rather than
/// interleaved, or parked for minutes on a thread with nothing to report.
private enum InstallLock {
    static func holding<T>(_ directory: URL, _ body: () async throws -> T) async throws -> T {
        let lock = directory.appending(components: "installed", ".lock")
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lock.path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw ModelStoreError.lockUnavailable(lock: lock, errno: errno)
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw errno == EWOULDBLOCK
                ? ModelStoreError.installInProgress(lock: lock)
                : ModelStoreError.lockUnavailable(lock: lock, errno: errno)
        }
        return try await body()
    }
}

public enum ModelStoreError: Error, Equatable, CustomStringConvertible {
    case manifestUnreadable(manifest: URL, reason: String)
    case installInProgress(lock: URL)
    case lockUnavailable(lock: URL, errno: Int32)

    public var description: String {
        switch self {
        case .manifestUnreadable(let manifest, let reason):
            "manifest \(manifest.path) cannot be read (\(reason)); delete it and the model's folder under models, beside installed, then download again"
        case .installInProgress(let lock):
            "another install holds \(lock.path); wait for it to finish"
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
/// Every path is relative and stays under whatever root it is appended to:
/// `init(recording:)` cuts its paths from real URLs beneath the root, and decoding
/// refuses any other shape, so a `Manifest` in hand cannot reach outside a store.
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
    public init(recording folder: URL, relativeTo root: URL) throws {
        let rootPath = root.standardizedFileURL.path
        let folderPath = folder.standardizedFileURL.path
        guard folderPath.hasPrefix(rootPath + "/") else {
            throw ManifestError.folderOutsideRoot(folder: folder, root: root)
        }
        self.folder = String(folderPath.dropFirst(rootPath.count + 1))

        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            throw ManifestError.unreadableFolder(folder)
        }
        var files: [File] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize else { continue }
            let path = url.standardizedFileURL.path
            files.append(File(path: String(path.dropFirst(folderPath.count + 1)), size: Int64(size)))
        }
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

    /// The listed files that are not in `folder` at their recorded size; empty
    /// means whole. Extra files are not damage: the hub may add sidecars, and they
    /// carry no model weight.
    public func faults(in folder: URL) -> [Fault] {
        files.compactMap { file in
            let url = folder.appending(path: file.path)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) else {
                return Fault(path: file.path, kind: .missing)
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
        }

        public init(path: String, kind: Kind) {
            self.path = path
            self.kind = kind
        }

        public var description: String {
            switch kind {
            case .missing: "\(path) is missing"
            case .wrongSize(let expected, let actual): "\(path) is \(actual) bytes, expected \(expected)"
            }
        }
    }
}

public enum ManifestError: Error, Equatable, CustomStringConvertible {
    case folderOutsideRoot(folder: URL, root: URL)
    case unreadableFolder(URL)
    /// A recorded path that is absolute, or has an empty, `.`, or `..` step.
    case pathEscapes(String)

    public var description: String {
        switch self {
        case .folderOutsideRoot(let folder, let root):
            "model folder \(folder.path) is not inside the store \(root.path)"
        case .unreadableFolder(let folder):
            "cannot list \(folder.path)"
        case .pathEscapes(let path):
            "manifest path \(path) would leave the store"
        }
    }
}
