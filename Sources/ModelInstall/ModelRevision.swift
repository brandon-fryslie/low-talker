import Foundation
import LowTalkerCore
import WhisperKit

/// Which Hugging Face commits a model's two parts come from: the whisperkit-coreml commit
/// of its weights and the openai commit of the tokenizer they decode with.
///
/// Two answers exist and must agree: `upstream(of:)`, what a fetch from huggingface.co
/// would bring now, and `ModelStore.revision(of:)`, what a store's fetch brought. The
/// hub client fetches `main` and takes no revision, so neither can be pinned; a release
/// names its cached store by the first and holds the store to it with the second.
public struct ModelRevision: Hashable, Sendable, LosslessStringConvertible {
    public let weights: Commit
    public let tokenizer: Commit

    public init(weights: Commit, tokenizer: Commit) {
        self.weights = weights
        self.tokenizer = tokenizer
    }

    /// `<weights commit>-<tokenizer commit>`, the form a cache key takes it in.
    public var description: String { "\(weights)-\(tokenizer)" }

    public init?(_ description: String) {
        let commits = description.split(separator: "-", omittingEmptySubsequences: false).map { Commit(String($0)) }
        guard commits.count == 2, let weights = commits[0], let tokenizer = commits[1] else { return nil }
        self.init(weights: weights, tokenizer: tokenizer)
    }

    /// A git commit hash as the hub writes it: 40 lowercase hex digits.
    public struct Commit: Hashable, Sendable, LosslessStringConvertible {
        public let description: String

        public init?(_ description: String) {
            guard description.count == 40, description.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
            self.description = description
        }
    }

    /// The repo whisperkit-coreml weights come from, which `install` fetches from too.
    static let weightsRepo = "argmaxinc/whisperkit-coreml"

    /// The revision a fetch of `model` from huggingface.co would bring now: the commit
    /// `main` names in the weights repo, and in the tokenizer repo those weights' config
    /// picks. Asks the hub three small questions and downloads no weights.
    public static func upstream(of model: ModelName) async throws -> ModelRevision {
        try await upstream(of: model, asking: Hub.get)
    }

    /// [LAW:effects-at-boundaries] The questions and what is made of the answers, with
    /// the asking handed in, so the answers can be ones captured from the hub.
    static func upstream(of model: ModelName, asking get: (URL) async throws -> Data) async throws -> ModelRevision {
        let weights = try await JSONDecoder().decode(Hub.Revision.self, from: get(Hub.main(of: weightsRepo)))
        let folder = try variantFolder(of: model, among: weights.files)
        let config = try await get(Hub.file("\(folder)/config.json", in: weightsRepo, at: weights.commit))
        let tokenizer = try await JSONDecoder().decode(Hub.Revision.self, from: get(Hub.main(of: ModelVariant(modelConfig: config).tokenizerRepo)))
        return ModelRevision(weights: weights.commit, tokenizer: tokenizer.commit)
    }

    /// The repo folder a download of `model` takes, chosen from `files` as
    /// `WhisperKit.download` chooses it: the one folder whose files match
    /// `*<model>/*`, or failing that the one matching `*openai*<model>/*`.
    ///
    /// [LAW:one-source-of-truth] exception: WhisperKit makes this choice inside the
    /// download and exposes no function for it. A mirror that drifts picks another
    /// folder's config, names another tokenizer commit, and `download --revision` fails
    /// on the store that disagrees.
    static func variantFolder(of model: ModelName, among files: [String]) throws -> String {
        let candidates = ["*\(model.rawValue)/*", "*openai*\(model.rawValue)/*"].map { (glob: String) in
            Set(files.filter { fnmatch(glob, $0, 0) == 0 }.compactMap { $0.split(separator: "/").first.map(String.init) })
        }
        guard let folders = candidates.first(where: { $0.count == 1 }) else {
            throw ModelRevisionError.noVariantFolder(model: model, matches: candidates[0].sorted())
        }
        return folders.first!
    }
}

extension ModelStore {
    /// The revision the installed model was fetched at, read from the commit the hub
    /// client recorded beside each file the manifests list. Throws when a part is not
    /// installed whole, when a file has no such record (a store installed by copying
    /// carries none), or when a part's files came from more than one commit.
    public func revision(of model: ModelName) throws -> ModelRevision {
        try ModelRevision(weights: commit(.weights, of: model), tokenizer: commit(.tokenizer, of: model))
    }

    /// Nothing, when the installed model is exactly `expected`; an error naming both
    /// revisions otherwise.
    public func require(_ expected: ModelRevision, of model: ModelName) throws {
        let held = try revision(of: model)
        guard held == expected else { throw ModelRevisionError.mismatch(model: model, expected: expected, held: held) }
    }

    /// The hub client keeps its record of `models/<org>/<repo>/<path>` at
    /// `models/<org>/<repo>/.cache/huggingface/download/<path>.metadata`, the commit on
    /// its first line.
    private func commit(_ part: ModelPart, of model: ModelName) throws -> ModelRevision.Commit {
        guard case .whole(let manifest) = try recording(part, of: model) else {
            throw ModelRevisionError.notInstalled(model: model, part: part)
        }
        let steps = manifest.folder.split(separator: "/").map(String.init)
        let sidecars = directory.appending(path: steps.prefix(3).joined(separator: "/")).appending(components: ".cache", "huggingface", "download")
        let commits = try Set(manifest.files.map { file in
            let sidecar = sidecars.appending(path: (steps.dropFirst(3) + [file.path]).joined(separator: "/") + ".metadata")
            let record = try String(contentsOf: sidecar, encoding: .utf8)
            guard let line = record.split(separator: "\n").first, let commit = ModelRevision.Commit(String(line)) else {
                throw ModelRevisionError.unreadableSidecar(sidecar)
            }
            return commit
        })
        guard commits.count == 1, let commit = commits.first else {
            throw ModelRevisionError.mixedCommits(model: model, part: part, commits: commits.map(\.description).sorted())
        }
        return commit
    }
}

/// The two hub questions `upstream(of:)` asks, over the endpoint WhisperKit fetches from.
enum Hub {
    struct Revision: Decodable {
        let commit: ModelRevision.Commit
        let files: [String]

        private enum CodingKeys: String, CodingKey { case sha, siblings }
        private struct Sibling: Decodable { let rfilename: String }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let sha = try container.decode(String.self, forKey: .sha)
            guard let commit = ModelRevision.Commit(sha) else {
                throw DecodingError.dataCorruptedError(forKey: .sha, in: container, debugDescription: "not a commit: \(sha)")
            }
            self.commit = commit
            files = try container.decode([Sibling].self, forKey: .siblings).map(\.rfilename)
        }
    }

    static let endpoint = URL(string: Constants.defaultRemoteEndpoint)!

    /// Answered by the commit `main` names in `repo`, and the files it holds.
    static func main(of repo: String) -> URL {
        endpoint.appending(path: "api/models/\(repo)/revision/main")
    }

    static func file(_ path: String, in repo: String, at commit: ModelRevision.Commit) -> URL {
        endpoint.appending(path: "\(repo)/resolve/\(commit)/\(path)")
    }

    static func get(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == 200 else { throw ModelRevisionError.hubRefused(url: url, status: status) }
        return data
    }
}

public enum ModelRevisionError: Error, Equatable, CustomStringConvertible {
    case hubRefused(url: URL, status: Int?)
    /// No single folder in the weights repo is the model's, so no download could take one.
    case noVariantFolder(model: ModelName, matches: [String])
    case notInstalled(model: ModelName, part: ModelPart)
    case unreadableSidecar(URL)
    case mixedCommits(model: ModelName, part: ModelPart, commits: [String])
    case mismatch(model: ModelName, expected: ModelRevision, held: ModelRevision)

    public var description: String {
        switch self {
        case .hubRefused(let url, let status):
            "\(url.absoluteString) answered \(status.map { "HTTP \($0)" } ?? "with no HTTP status")"
        case .noVariantFolder(let model, let matches):
            "no single folder in \(ModelRevision.weightsRepo) holds \(model): \(matches.isEmpty ? "none match" : matches.joined(separator: ", "))"
        case .notInstalled(let model, let part):
            "the \(part) of \(model) is not installed whole"
        case .unreadableSidecar(let url):
            "\(url.path) records no commit"
        case .mixedCommits(let model, let part, let commits):
            "the \(part) of \(model) came from more than one commit: \(commits.joined(separator: ", "))"
        case .mismatch(let model, let expected, let held):
            "\(model) was fetched at \(held), not \(expected)"
        }
    }
}
