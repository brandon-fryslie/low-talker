import Foundation
import WhisperKit

/// The on-disk home of engine models: one directory laid out the way the Hugging
/// Face hub lays out its cache, so WhisperKit's downloader and tokenizer loader
/// find their files without being told twice where they are.
///
/// [LAW:one-source-of-truth] "Is the model here and whole?" has one answer: the
/// manifest the store wrote after the last complete download. The hub's own sidecar
/// files prove each file arrived intact; the manifest proves the *set* is complete,
/// which the sidecars cannot, since a download stopped between files leaves no
/// trace of the files it never started.
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
    public func presence(of model: WhisperKitTranscriber.Model) -> Presence {
        let manifest: Manifest
        do {
            manifest = try Manifest(contentsOf: manifestURL(for: model))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .damaged("manifest unreadable: \(error)")
        }
        let folder = directory.appending(path: manifest.folder)
        do {
            try manifest.verify(against: folder)
        } catch {
            return .damaged("\(error)")
        }
        return .installed(InstalledModel(model: model, folder: folder, hub: directory))
    }

    /// Downloads the model into the store, or finishes a download that stopped, then
    /// records the manifest that makes it `.installed`. The hub client skips files
    /// already here whose hash matches, so calling this on a damaged install costs
    /// only the missing parts.
    public func install(
        _ model: WhisperKitTranscriber.Model,
        progress: @escaping @Sendable (_ fractionCompleted: Double) -> Void
    ) async throws -> InstalledModel {
        let folder = try await WhisperKit.download(variant: model.rawValue, downloadBase: directory) { progress($0.fractionCompleted) }
        // [LAW:no-silent-failure] The hub client answers cancellation by returning
        // the folder as far as it got, without throwing. A manifest over that folder
        // would certify a partial model as whole.
        try Task.checkCancellation()
        let manifest = try Manifest(recording: folder, relativeTo: directory)
        try manifest.write(to: manifestURL(for: model))
        return InstalledModel(model: model, folder: folder, hub: directory)
    }

    private func manifestURL(for model: WhisperKitTranscriber.Model) -> URL {
        directory.appending(components: "installed", "\(model.rawValue).json")
    }

    public enum Presence: Sendable {
        case installed(InstalledModel)
        /// Never downloaded here.
        case missing
        /// Downloaded once, but a file the manifest lists is gone or the wrong size.
        case damaged(String)
    }
}

/// Proof that a model's files are all present in a store. Only `ModelStore` makes
/// one, so holding it means the check ran.
public struct InstalledModel: Sendable {
    public let model: WhisperKitTranscriber.Model
    /// The folder holding the `.mlmodelc` bundles and config.
    public let folder: URL
    /// The store root, where the tokenizer for this model lives or will be fetched.
    public let hub: URL

    fileprivate init(model: WhisperKitTranscriber.Model, folder: URL, hub: URL) {
        self.model = model
        self.folder = folder
        self.hub = hub
    }
}

/// The set of files a complete download produced, with their sizes: a snapshot of
/// what "whole" means for one model, written once and checked on every launch.
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

    public init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Every listed file exists in `folder` at its recorded size. Extra files are
    /// not damage: the hub may add sidecars, and they carry no model weight.
    public func verify(against folder: URL) throws {
        for file in files {
            let url = folder.appending(path: file.path)
            let size: Int64
            do {
                size = try Int64(url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            } catch {
                throw ManifestError.fileMissing(file.path)
            }
            guard size == file.size else {
                throw ManifestError.fileWrongSize(file.path, expected: file.size, actual: size)
            }
        }
    }
}

public enum ManifestError: Error, CustomStringConvertible {
    case folderOutsideRoot(folder: URL, root: URL)
    case unreadableFolder(URL)
    case fileMissing(String)
    case fileWrongSize(String, expected: Int64, actual: Int64)

    public var description: String {
        switch self {
        case .folderOutsideRoot(let folder, let root):
            "model folder \(folder.path) is not inside the store \(root.path)"
        case .unreadableFolder(let folder):
            "cannot list \(folder.path)"
        case .fileMissing(let path):
            "\(path) is missing"
        case .fileWrongSize(let path, let expected, let actual):
            "\(path) is \(actual) bytes, expected \(expected)"
        }
    }
}
