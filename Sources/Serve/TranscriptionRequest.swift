import Foundation
import LowTalkerCore

/// `POST /v1/audio/transcriptions`, parsed: the fields OpenAI's spec defines that this
/// server honors, and nothing else.
///
/// [LAW:parse-dont-validate] A value in hand has a non-empty file, a format the server can
/// write, and a vocabulary the engine can be told; every refusal happened in `parse`.
struct TranscriptionRequest: Sendable {
    let upload: Upload
    let format: ResponseFormat
    let vocabulary: Vocabulary
    /// Accepted whatever it names; the answer never claims to be that model.
    let model: String
    let language: Language?

    /// The fields this server reads. Any other field is refused by name rather than
    /// ignored, so a client asking for behavior the server lacks (a stream, word
    /// timestamps) hears so instead of getting an answer it did not ask for.
    /// [LAW:no-silent-failure]
    private static let known: Set = ["file", "model", "language", "prompt", "response_format"]

    static func parse(_ fields: [FormField]) throws(APIError) -> TranscriptionRequest {
        var byName: [String: FormField] = [:]
        for field in fields {
            guard known.contains(field.name) else { throw .unsupportedParameter(field.name) }
            guard byName.updateValue(field, forKey: field.name) == nil else { throw .repeated(field: field.name) }
        }
        guard let file = byName["file"] else { throw .missing(field: "file") }
        guard let model = byName["model"] else { throw .missing(field: "model") }
        let format = try ResponseFormat.parse(byName["response_format"].map(\.text) ?? ResponseFormat.json.rawValue)
        return TranscriptionRequest(
            upload: try Upload(bytes: file.value, filename: file.filename),
            format: format,
            vocabulary: try prompted(byName["prompt"]?.text),
            model: model.text,
            language: try byName["language"].map { field throws(APIError) in try Language.parse(field.text) }
        )
    }

    private static func prompted(_ prompt: String?) throws(APIError) -> Vocabulary {
        do {
            return try Vocabulary(prompt: prompt)
        } catch {
            throw .promptRefused("\(error)")
        }
    }
}

extension Vocabulary {
    /// A transcription's prompt as the vocabulary a dictation mode would give the engine:
    /// one term, spelled as the client wrote it. No prompt, or one with no word in it,
    /// expects nothing beyond ordinary speech, which is the empty vocabulary.
    /// [LAW:one-source-of-truth] REST's `prompt` and Realtime's are read by this one rule.
    init(prompt: String?) throws(VocabularyError) {
        guard let prompt else {
            self.init([])
            return
        }
        do {
            self.init([try Vocabulary.Term(prompt)])
        } catch .termSaysNothing {
            self.init([])
        }
    }
}

/// What a transcription is billed as, whatever model was named: the audio's duration in
/// whole seconds, rounded up as OpenAI counts it.
struct Usage: Encodable, Sendable {
    let type = "duration"
    let seconds: Int

    init(heard duration: TimeInterval) {
        seconds = Int(duration.rounded(.up))
    }
}

extension Transcript {
    /// The transcript as OpenAI writes it. The engine's words carry their leading space,
    /// which OpenAI's text does not.
    var served: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The two answers a transcription can take. [LAW:types-are-the-program] Any other
/// `response_format` is refused at parse, so rendering cannot meet one.
enum ResponseFormat: String, Sendable, Codable {
    case json
    case text

    static func parse(_ value: String) throws(APIError) -> ResponseFormat {
        guard let format = ResponseFormat(rawValue: value) else { throw .unsupportedValue(field: "response_format", value: value, accepted: "json or text") }
        return format
    }

    /// The answer as OpenAI gives it (epic low-serve-axq): json is the text and its usage;
    /// text is the transcript and a newline.
    func response(_ transcript: Transcript, heard audio: AudioClip) -> HTTPResponse {
        let text = transcript.served
        switch self {
        case .json:
            let body = JSONBody(text: text, usage: Usage(heard: audio.duration))
            return HTTPResponse(status: .ok, contentType: "application/json", body: JSONEncoder.served.encodeAlways(body))
        case .text:
            return HTTPResponse(status: .ok, contentType: "text/plain; charset=utf-8", body: Data((text + "\n").utf8))
        }
    }

    private struct JSONBody: Encodable {
        let text: String
        let usage: Usage
    }
}

/// The languages the engine hears. WhisperKit decodes as English whenever it is not told
/// otherwise (`Constants.defaultLanguageCode`), and LowTalker never tells it otherwise, so
/// a request for another language is refused rather than answered in English.
/// [LAW:no-silent-failure]
enum Language: String, Sendable, CaseIterable {
    case english = "en"

    /// The names a request may give, as a refusal lists them.
    static var accepted: String { allCases.map(\.rawValue).joined(separator: " or ") }

    static func parse(_ value: String) throws(APIError) -> Language {
        guard let language = Language(rawValue: value) else { throw .unsupportedValue(field: "language", value: value, accepted: accepted) }
        return language
    }
}

/// An uploaded audio file with at least one byte in it.
struct Upload: Sendable {
    let bytes: Data
    let filename: String?

    init(bytes: Data, filename: String?) throws(APIError) {
        guard !bytes.isEmpty else { throw .emptyFile }
        self.bytes = bytes
        self.filename = filename
    }

    /// The file as a clip of at most `longest` seconds, read by the one reader every audio
    /// file in LowTalker goes through, which refuses a longer one before decoding it. AVFoundation reads files, not bytes, so the upload is written to a
    /// temporary file named with the upload's extension, which is AVFoundation's hint for
    /// the format, and removed once read.
    func clip(longest: TimeInterval) throws(APIError) -> AudioClip {
        let pathExtension = filename.map { ($0 as NSString).pathExtension } ?? ""
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lowtalker-upload-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try bytes.write(to: url)
        } catch {
            throw .uploadNotStored("\(error)")
        }
        let clip: AudioClip
        do {
            clip = try AudioClip(contentsOf: url, longest: longest)
        } catch AudioClipError.longerThan(let limit, let seconds) {
            throw .audioTooLong(seconds: seconds, limit: limit)
        } catch AudioClipError.unreadable(_, let underlying) {
            // The temporary file's path is the server's business, not the client's.
            throw .unreadableAudio("\(underlying)")
        } catch {
            throw .unreadableAudio("\(error)")
        }
        guard !clip.samples.isEmpty else { throw .silentFile }
        return clip
    }
}

extension FormField {
    /// A field's value as the text a form's non-file fields are.
    var text: String { String(decoding: value, as: UTF8.self) }
}
