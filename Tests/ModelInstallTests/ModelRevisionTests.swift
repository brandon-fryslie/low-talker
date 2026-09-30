import Foundation
import LowTalkerCore
@testable import ModelInstall
import TestProbes
import Testing

/// Which commits a store holds, read off the hub client's sidecars on a scratch store.
/// What huggingface.co answers needs the network, so `lowtalker model revision` is
/// checked against it on a Mac, not here.
@Suite struct ModelRevisionTests {
    static let weights = ModelRevision.Commit(String(repeating: "a", count: 40))!
    static let tokenizer = ModelRevision.Commit(String(repeating: "b", count: 40))!
    static let revision = ModelRevision(weights: weights, tokenizer: tokenizer)

    @Test func revisionReadsBackFromItsDescription() {
        #expect(ModelRevision(Self.revision.description) == Self.revision)
    }

    @Test(arguments: [
        "", String(repeating: "a", count: 40),
        "\(String(repeating: "a", count: 40))-\(String(repeating: "B", count: 40))",
        "\(String(repeating: "a", count: 39))-\(String(repeating: "b", count: 40))",
        "\(String(repeating: "a", count: 40))-\(String(repeating: "b", count: 40))-\(String(repeating: "c", count: 40))",
    ])
    func revisionRefusesWhatIsNotTwoCommits(text: String) {
        #expect(ModelRevision(text) == nil)
    }

    /// The three questions, answered as huggingface.co answered them on 2026-09-30 (siblings
    /// cut to the ones near the default model): the weights' commit, their config at that
    /// commit, and the commit of the tokenizer repo the config picks.
    @Test func upstreamAsksForTheWeightsThenTheTokenizerTheirConfigPicks() async throws {
        let weights = "0f63a7800b00dd0226abd051b906c246e1907482"
        let tokenizer = "06f233fe06e710322aca913c1bc4249a0d71fce1"
        let answers = [
            "https://huggingface.co/api/models/argmaxinc/whisperkit-coreml/revision/main": """
                {"id": "argmaxinc/whisperkit-coreml", "sha": "\(weights)", "siblings": [
                  {"rfilename": "openai_whisper-large-v3-v20240930_turbo/config.json"},
                  {"rfilename": "openai_whisper-large-v3-v20240930_turbo_632MB/config.json"},
                  {"rfilename": "openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc/weights/weight.bin"}]}
                """,
            "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/\(weights)/openai_whisper-large-v3-v20240930_turbo_632MB/config.json": """
                {"d_model": 1280, "model_type": "whisper", "vocab_size": 51866}
                """,
            "https://huggingface.co/api/models/openai/whisper-large-v3/revision/main": """
                {"id": "openai/whisper-large-v3", "sha": "\(tokenizer)", "siblings": [{"rfilename": "tokenizer.json"}]}
                """,
        ]
        let revision = try await ModelRevision.upstream(of: "large-v3-v20240930_turbo_632MB") { url in
            try Data(#require(answers[url.absoluteString], "asked \(url)").utf8)
        }
        #expect(revision == ModelRevision("\(weights)-\(tokenizer)"))
    }

    @Test func variantFolderIsTheOneFolderMatchingTheModel() throws {
        let files = ["openai_whisper-large-v3/config.json", "openai_whisper-large-v3_turbo/config.json", "README.md"]
        #expect(try ModelRevision.variantFolder(of: "large-v3", among: files) == "openai_whisper-large-v3")
    }

    /// WhisperKit narrows a name two folders end in to the openai one.
    @Test func variantFolderPrefersOpenAIWhenTwoFoldersMatch() throws {
        let files = ["distil-whisper_large-v3/config.json", "openai_whisper-large-v3/config.json"]
        #expect(try ModelRevision.variantFolder(of: "large-v3", among: files) == "openai_whisper-large-v3")
    }

    @Test func variantFolderRefusesAModelNoFolderHolds() {
        #expect(throws: ModelRevisionError.noVariantFolder(model: "tiny", matches: [])) {
            try ModelRevision.variantFolder(of: "tiny", among: ["openai_whisper-large-v3/config.json"])
        }
    }

    @Test func storeRevisionIsTheCommitEachPartsFilesCameFrom() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        try scratch.record()
        try scratch.writeSidecars(weights: Self.weights, tokenizer: Self.tokenizer)
        let store = ModelStore(directory: scratch.root)
        #expect(try store.revision(of: "test") == Self.revision)
        try store.require(Self.revision, of: "test")
    }

    @Test func requireRefusesAStoreFetchedAtAnotherRevision() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        try scratch.record()
        try scratch.writeSidecars(weights: Self.weights, tokenizer: Self.tokenizer)
        let other = ModelRevision(weights: Self.tokenizer, tokenizer: Self.tokenizer)
        #expect(throws: ModelRevisionError.mismatch(model: "test", expected: other, held: Self.revision)) {
            try ModelStore(directory: scratch.root).require(other, of: "test")
        }
    }

    /// A file refetched after upstream moved leaves a part that is no one commit.
    @Test func storeRevisionRefusesAPartFromTwoCommits() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        try scratch.record()
        try scratch.writeSidecars(weights: Self.weights, tokenizer: Self.tokenizer)
        try scratch.writeSidecar(for: "config.json", commit: Self.tokenizer)
        #expect(throws: ModelRevisionError.mixedCommits(model: "test", part: .weights, commits: [Self.weights.description, Self.tokenizer.description])) {
            try ModelStore(directory: scratch.root).revision(of: "test")
        }
    }

    /// A store installed by copying carries no sidecars, so it has no revision to show.
    @Test func storeRevisionRefusesAStoreWithoutSidecars() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        try scratch.record()
        #expect(throws: (any Error).self) {
            try ModelStore(directory: scratch.root).revision(of: "test")
        }
    }

    @Test func storeRevisionRefusesAModelNotInstalled() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        #expect(throws: ModelRevisionError.notInstalled(model: "test", part: .weights)) {
            try ModelStore(directory: scratch.root).revision(of: "test")
        }
    }
}

extension ScratchStore {
    /// Writes the hub client's record of the commit beside every file of both parts.
    func writeSidecars(weights: ModelRevision.Commit, tokenizer: ModelRevision.Commit) throws {
        for path in Self.files.keys { try writeSidecar(for: path, commit: weights) }
        for path in Self.tokenizerFiles.keys {
            try write(commit: tokenizer, to: root.appending(components: "models", "openai", "whisper-test", ".cache", "huggingface", "download").appending(path: "\(path).metadata"))
        }
    }

    /// Records `commit` for one file of the weights.
    func writeSidecar(for path: String, commit: ModelRevision.Commit) throws {
        try write(commit: commit, to: root.appending(components: "models", "argmaxinc", "whisperkit-coreml", ".cache", "huggingface", "download", "openai_whisper-test").appending(path: "\(path).metadata"))
    }

    private func write(commit: ModelRevision.Commit, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "\(commit)\n\"etag\"\n1790722675.9\n".write(to: url, atomically: true, encoding: .utf8)
    }
}
