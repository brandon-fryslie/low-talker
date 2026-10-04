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

    /// The three questions, answered as huggingface.co answered them on 2026-10-04 (siblings
    /// cut to the ones near the default model, blob ids left out): the weights' commit, their config at that
    /// commit, and the commit of the tokenizer repo the config picks.
    @Test func upstreamAsksForTheWeightsThenTheTokenizerTheirConfigPicks() async throws {
        let weights = "0f63a7800b00dd0226abd051b906c246e1907482"
        let tokenizer = "06f233fe06e710322aca913c1bc4249a0d71fce1"
        let answers = [
            "https://huggingface.co/api/models/argmaxinc/whisperkit-coreml/revision/main?blobs=true": """
                {"id": "argmaxinc/whisperkit-coreml", "sha": "\(weights)", "siblings": [
                  {"rfilename": "openai_whisper-large-v3-v20240930_turbo/config.json", "size": 2244},
                  {"rfilename": "openai_whisper-large-v3-v20240930_turbo_632MB/config.json", "size": 2244},
                  {"rfilename": "openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc/weights/weight.bin", "size": 421968768,
                   "lfs": {"sha256": "e4740fa28ed65907af754af893dfce98473fafb84dd8d718ad346985fe7678c1", "size": 421968768, "pointerSize": 134}}]}
                """,
            "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/\(weights)/openai_whisper-large-v3-v20240930_turbo_632MB/config.json": """
                {"d_model": 1280, "model_type": "whisper", "vocab_size": 51866}
                """,
            "https://huggingface.co/api/models/openai/whisper-large-v3/revision/main?blobs=true": """
                {"id": "openai/whisper-large-v3", "sha": "\(tokenizer)", "siblings": [{"rfilename": "tokenizer.json", "size": 2480617}]}
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

    /// A listing without sizes cannot say what whole is, so it is refused rather than
    /// read as files of no particular size.
    @Test func listingWithoutSizesIsRefused() {
        let listing = #"{"sha": "\#(Self.weights)", "siblings": [{"rfilename": "config.json"}]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Hub.Revision.self, from: Data(listing.utf8))
        }
    }

    /// The weights' manifest is the variant folder's files, at the sizes the hub lists,
    /// under paths relative to that folder.
    @Test func manifestTakesTheHubSizesOfTheSelectedFiles() throws {
        let listing = try JSONDecoder().decode(Hub.Revision.self, from: Data("""
            {"sha": "\(Self.weights)", "siblings": [
              {"rfilename": "README.md", "size": 5},
              {"rfilename": "openai_whisper-test/config.json", "size": 2244},
              {"rfilename": "openai_whisper-test/AudioEncoder.mlmodelc/weights/weight.bin", "size": 421968768}]}
            """.utf8))
        let store = URL(filePath: "/store")
        let manifest = try listing.manifest(of: store.appending(path: "models/argmaxinc/whisperkit-coreml/openai_whisper-test"), in: store) { path in
            path.hasPrefix("openai_whisper-test/") ? String(path.dropFirst("openai_whisper-test/".count)) : nil
        }
        #expect(manifest == (try Manifest(folder: "models/argmaxinc/whisperkit-coreml/openai_whisper-test", files: [
            .init(path: "AudioEncoder.mlmodelc/weights/weight.bin", size: 421968768),
            .init(path: "config.json", size: 2244),
        ])))
    }
}
