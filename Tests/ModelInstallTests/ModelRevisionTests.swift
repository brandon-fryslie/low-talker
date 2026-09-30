import Foundation
import LowTalkerCore
@testable import ModelInstall
import Testing

/// What a revision is, and how the one `main` names is found, from answers captured from
/// huggingface.co. A fetch at a revision needs the network, so it is checked by
/// model-cache.yml's run, not here.
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
        "\(String(repeating: "a", count: 40))-\(String(repeating: "ｂ", count: 40))",
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
        #expect(throws: ModelInstallError.noVariantFolder(model: "tiny", matches: [])) {
            try ModelRevision.variantFolder(of: "tiny", among: ["openai_whisper-large-v3/config.json"])
        }
    }
}
