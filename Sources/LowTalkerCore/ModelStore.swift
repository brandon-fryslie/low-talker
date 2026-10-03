import Foundation

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
///
/// [LAW:one-way-deps] This is the read side: whether a model is here and whole, and the
/// proof a load takes. Writing a store - fetching what it lacks, copying from another
/// store, packing one to publish - is `ModelInstall`'s, a module the CLI links and the
/// app does not, so a process linking only this one has no way to reach the network for
/// a model.
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

    /// The folder in an app bundle's resources where the bundle carries a store holding
    /// its model, so a first launch has something to load with the network off.
    ///
    /// [LAW:one-source-of-truth] project.yml copies the store in under its
    /// `MODEL_STORE_RESOURCE` setting, which xcodegen cannot read from Swift;
    /// `CarriedModelStoreTests` holds that copy to this one.
    public static let carriedResourceName = "model-store"

    /// The store `bundle` carries, if it carries one. Every bundle `make app` builds does;
    /// only a bundle built with
    /// `BUNDLED_MODEL_STORE=` (CI's, with no model to carry) does not.
    ///
    /// The app loads this store in place, read-only, and writes no model data outside
    /// its bundle: the carried store is already whole and sealed by the code signature, so
    /// nothing has to be copied out of it first. Inside the bundle rather than beside it on
    /// the disk image, because dragging the app to Applications takes the bundle and leaves
    /// whatever sat beside it behind.
    public static func carried(by bundle: Bundle) -> ModelStore? {
        bundle.url(forResource: carriedResourceName, withExtension: nil).map(ModelStore.init(directory:))
    }

    /// Where the model stands on disk. Only `.installed` yields the proof a load
    /// needs; the other two are why an install is called. Throws when the store itself
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

    /// The model, verified present, or the reason the store does not hold it. A store
    /// already whole is loaded where it sits, with no lock and no write, which is how the
    /// app loads its carried, code-signed store. A store that is not whole cannot be made
    /// whole here — nothing to download, nowhere to write — so it fails with the part-level
    /// reason rather than a permission error from a lock it could not take.
    /// [LAW:parse-dont-validate] [LAW:no-silent-failure]
    public func installedModel(_ model: ModelName) throws -> InstalledModel {
        switch try presence(of: model) {
        case .installed(let installed): return installed
        case .missing: throw ModelStoreError.storeLacksModel(store: directory, model: model, reason: "the model is not installed")
        case .damaged(let damages): throw ModelStoreError.storeLacksModel(store: directory, model: model, reason: damages.map { "\($0)" }.joined(separator: "; "))
        }
    }

    /// The models whose weights this store has recorded, by name, in order: what a bench can
    /// ask it for. Whether each is whole is `installedModel`'s to say as it loads. Throws for
    /// a folder that has never been a store, which has no record to list.
    public func recordedModels() throws -> [ModelName] {
        try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "installed").path)
            .filter { $0.hasSuffix(".json") }
            .compactMap { ModelName(rawValue: String($0.dropLast(".json".count))) }
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// What one part's manifest says about its files.
    package enum Recording {
        case whole(Manifest)
        case unrecorded
        case damaged(Damage)
    }

    package func recording(_ part: ModelPart, of model: ModelName) throws -> Recording {
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

    /// `installed/<model>.json` for the weights, where every store before the
    /// tokenizer had a manifest already wrote it, and `installed/tokenizer/<model>.json`
    /// beside it. Kept per model rather than per tokenizer: a model knows its own
    /// manifests' names without reading its weights.
    package func manifestURL(for model: ModelName, _ part: ModelPart) -> URL {
        let installed = directory.appending(path: "installed")
        return switch part {
        case .weights: installed.appending(path: "\(model.rawValue).json")
        case .tokenizer: installed.appending(components: "tokenizer", "\(model.rawValue).json")
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

/// A part of a model, as a store installs it and a manifest records it.
public enum ModelPart: String, Sendable, CustomStringConvertible {
    /// The Core ML bundles and the model's config, in the whisperkit-coreml repo.
    case weights
    /// The tokenizer the weights decode with, in an openai repo shared by every model
    /// of one Whisper size.
    case tokenizer

    public var description: String { rawValue }

    /// Where this part's files live in a store, in the words a repair instruction uses.
    var folderDescription: String {
        switch self {
        case .weights: "model's folder under models/argmaxinc/whisperkit-coreml"
        case .tokenizer: "tokenizer's folder under models/openai"
        }
    }
}

public enum ModelStoreError: Error, Equatable, CustomStringConvertible {
    case manifestUnreadable(manifest: URL, part: ModelPart, reason: String)
    /// A store that does not hold the model whole, with no source to make it whole from:
    /// the app's read-only carried store, verified in place. [LAW:no-silent-failure]
    case storeLacksModel(store: URL, model: ModelName, reason: String)

    public var description: String {
        switch self {
        case .manifestUnreadable(let manifest, let part, let reason):
            // The folder a manifest covered is named by the manifest, which is what
            // cannot be read, so the instruction names where that part lives.
            "manifest \(manifest.path) cannot be read (\(reason)); delete it and the \(part.folderDescription), then download again"
        case .storeLacksModel(let store, let model, let reason):
            "\(store.path) does not hold \(model) whole: \(reason)"
        }
    }
}

/// Proof that a model's files are all present in a store. Only `ModelStore` makes
/// one, so holding it means the check ran: here on a read, and in `ModelInstall` once
/// an install has written both parts and their manifests.
public struct InstalledModel: Sendable {
    public let model: ModelName
    /// The folder holding the `.mlmodelc` bundles and config.
    public let folder: URL
    /// The store root, where the tokenizer for this model lives or will be fetched.
    public let hub: URL

    package init(model: ModelName, folder: URL, hub: URL) {
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
