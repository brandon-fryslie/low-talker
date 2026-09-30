import Foundation

/// Every way a request can fail, each answered in OpenAI's error shape:
/// `{"error": {"message", "type", "param", "code"}}`, all four keys present (epic
/// low-serve-axq).
///
/// [LAW:one-source-of-truth] A failure's status, words, parameter and code are read off its
/// case, so the answer a client gets and the event the server records cannot disagree.
enum APIError: Error, Equatable, Sendable {
    case malformed(String)
    case invalidAPIKey
    case lengthRequired
    case tooLarge(bytes: Int, limit: Int)
    case notFound(method: String, path: String)
    case missing(field: String)
    case repeated(field: String)
    case unsupportedParameter(String)
    case unsupportedValue(field: String, value: String, accepted: String)
    case promptRefused(String)
    case emptyFile
    case unreadableAudio(String)
    case silentFile
    case audioTooLong(seconds: TimeInterval, limit: TimeInterval)
    case busy(uploads: Int)
    case uploadNotStored(String)
    case notResident(String)
    case engineFailed(String)

    var status: Status {
        switch self {
        case .malformed, .missing, .repeated, .unsupportedParameter, .unsupportedValue, .promptRefused, .emptyFile, .unreadableAudio, .silentFile, .audioTooLong: .badRequest
        case .invalidAPIKey: .unauthorized
        case .lengthRequired: .lengthRequired
        case .tooLarge: .contentTooLarge
        case .notFound: .notFound
        case .busy: .tooManyRequests
        case .notResident: .serviceUnavailable
        case .uploadNotStored, .engineFailed: .internalServerError
        }
    }

    var message: String {
        switch self {
        case .malformed(let reason): "The request is malformed: \(reason)."
        case .invalidAPIKey: "Incorrect API key provided."
        case .lengthRequired: "The request body must have a content-length; chunked bodies are not accepted."
        case .tooLarge(let bytes, let limit): "The request body is \(bytes) bytes; the limit is \(limit)."
        case .notFound(let method, let path): "No endpoint answers \(method) \(path)."
        case .missing(let field): "The \(field) field is required."
        case .repeated(let field): "The \(field) field is given more than once."
        case .unsupportedParameter(let field): "The \(field) parameter is not supported."
        case .unsupportedValue(let field, let value, let accepted): "The \(field) \(value) is not supported; use \(accepted)."
        case .promptRefused(let reason): "The prompt cannot be used: \(reason)."
        case .emptyFile: "The audio file is empty."
        case .unreadableAudio(let reason): "The audio file could not be read: \(reason)."
        case .silentFile: "The audio file holds no audio."
        case .audioTooLong(let seconds, let limit): "The audio file holds \(Int(seconds.rounded(.up))) seconds of audio; the limit is \(Int(limit))."
        case .busy(let uploads): "The server is already transcribing \(uploads) uploads, as many as it takes at once; retry shortly."
        case .uploadNotStored(let reason): "The upload could not be stored for reading: \(reason)."
        case .notResident(let reason): "The model is not ready: \(reason)."
        case .engineFailed(let reason): "Transcription failed: \(reason)."
        }
    }

    var param: String? {
        switch self {
        case .missing(let field), .repeated(let field), .unsupportedParameter(let field), .unsupportedValue(let field, _, _): field
        case .promptRefused: "prompt"
        case .emptyFile, .unreadableAudio, .silentFile, .audioTooLong: "file"
        case .malformed, .invalidAPIKey, .lengthRequired, .tooLarge, .notFound, .uploadNotStored, .notResident, .engineFailed, .busy: nil
        }
    }

    var code: String {
        switch self {
        case .malformed: "malformed_request"
        case .invalidAPIKey: "invalid_api_key"
        case .lengthRequired: "length_required"
        case .tooLarge: "request_too_large"
        case .notFound: "unknown_url"
        case .missing: "missing_required_parameter"
        case .repeated: "repeated_parameter"
        case .unsupportedParameter: "unsupported_parameter"
        case .unsupportedValue: "unsupported_value"
        case .promptRefused: "invalid_value"
        case .emptyFile: "empty_file"
        case .unreadableAudio: "invalid_audio"
        case .silentFile: "audio_too_short"
        case .audioTooLong: "audio_too_long"
        case .busy: "rate_limit_exceeded"
        case .uploadNotStored: "upload_not_stored"
        case .notResident: "model_not_ready"
        case .engineFailed: "transcription_failed"
        }
    }

    var response: HTTPResponse {
        let type = status.rawValue >= 500 ? "server_error" : "invalid_request_error"
        let body = Body(error: .init(message: message, type: type, param: param, code: code))
        return HTTPResponse(status: status, contentType: "application/json", body: JSONEncoder.served.encodeAlways(body))
    }

    private struct Body: Encodable {
        let error: Detail

        struct Detail: Encodable {
            let message: String
            let type: String
            let param: String?
            let code: String

            // `param` is written as null when there is none: the shape has all four keys.
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(message, forKey: .message)
                try container.encode(type, forKey: .type)
                try container.encode(param, forKey: .param)
                try container.encode(code, forKey: .code)
            }

            enum CodingKeys: CodingKey { case message, type, param, code }
        }
    }
}

extension JSONEncoder {
    /// Every JSON this server writes: slashes as themselves and keys in one order, so a
    /// body or an event reads the same each time.
    static var served: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// A value made of strings, numbers and optionals only, whose encoding cannot fail.
    func encodeAlways(_ value: some Encodable) -> Data {
        // [LAW:no-silent-failure] A throw here is a programming error, so it traps.
        try! encode(value)
    }
}
