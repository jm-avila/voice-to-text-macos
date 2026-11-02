import Foundation

/// Turns an audio file into text. The app uses OpenAITranscriber; the
/// self-test and snapshots use a fake.
public protocol Transcribing: Sendable {
    func transcribe(_ file: URL, model: String, language: String?) async throws -> String
}

/// Why a transcription failed, in words the person can act on.
public enum TranscriptionError: LocalizedError, Equatable {
    case noKey
    case emptyRecording
    case tooLarge(bytes: Int)
    case api(status: Int, message: String)
    case network(String)
    case noWhisperCLI
    case noLocalModel
    case local(String)

    public var errorDescription: String? {
        switch self {
        case .noKey:
            "No OpenAI key. Add it to Keychain: secret set OPENAI_API_KEY -p openai --clip"
        case .emptyRecording:
            "The recording is empty"
        case .tooLarge(let bytes):
            "The recording is \(bytes / 1_048_576) MB; OpenAI takes up to 25 MB (about 70 minutes)"
        case .api(let status, let message):
            "API error \(status): \(message)"
        case .network(let message):
            "Request failed: \(message)"
        case .noWhisperCLI:
            "The local model needs whisper.cpp: brew install whisper-cpp"
        case .noLocalModel:
            "The local model is not downloaded. Run VoiceToText/tools/get-model.sh"
        case .local(let message):
            message
        }
    }
}

/// The multipart request for POST /audio/transcriptions, and how to read
/// the answer. response_format=text: a 200 body is the plain transcript.
public struct TranscriptionRequest: Sendable {
    public static let maxBytes = 25 * 1_048_576

    public var model: String
    /// ISO 639-1 ("en", "es"). nil lets the model detect the language.
    public var language: String?
    public var boundary = "vtt-\(UUID().uuidString)"

    public init(model: String, language: String?) {
        self.model = model
        self.language = language
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public func body(audio: Data, fileName: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", "text")
        if let language, !language.isEmpty { field("language", language) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// The transcript, one line, or the API's own error message.
    public static func interpret(status: Int, body: Data) throws -> String {
        let text = String(decoding: body, as: UTF8.self)
        guard status == 200 else {
            // Errors come as {"error": {"message": "..."}}. Show the message, not the JSON.
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let message = (object?["error"] as? [String: Any])?["message"] as? String
            throw TranscriptionError.api(status: status, message: message ?? Transcript.clean(text))
        }
        return Transcript.clean(text)
    }
}

/// OpenAI's transcription API, or any compatible one (OPENAI_BASE_URL).
public struct OpenAITranscriber: Transcribing {
    public var baseURL: URL
    public var session: URLSession
    /// Read on every request, so a key added while the app runs is used at once.
    public var key: @Sendable () -> String?

    public init(baseURL: URL = URL(string: "https://api.openai.com/v1")!, session: URLSession = .shared,
                key: @escaping @Sendable () -> String?) {
        self.baseURL = baseURL
        self.session = session
        self.key = key
    }

    public func transcribe(_ file: URL, model: String, language: String?) async throws -> String {
        guard let key = key(), !key.isEmpty else { throw TranscriptionError.noKey }
        guard let audio = try? Data(contentsOf: file), !audio.isEmpty else { throw TranscriptionError.emptyRecording }
        guard audio.count <= TranscriptionRequest.maxBytes else { throw TranscriptionError.tooLarge(bytes: audio.count) }
        let form = TranscriptionRequest(model: model, language: language)
        var request = URLRequest(url: baseURL.appending(path: "audio/transcriptions"), timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, from: form.body(audio: audio, fileName: file.lastPathComponent))
        } catch {
            throw TranscriptionError.network(error.localizedDescription)
        }
        return try TranscriptionRequest.interpret(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}

/// The OpenAI key, found the way the bash tool finds it: OPENAI_API_KEY in
/// the environment, else the Keychain item the `secret` CLI writes (service
/// OPENAI_API_KEY, account agent-secrets). It asks /usr/bin/security, which
/// created the item, so macOS shows no Keychain prompt.
public enum APIKey {
    public static func read(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let key = environment["OPENAI_API_KEY"], !key.isEmpty { return key }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", "agent-secrets", "-s", "OPENAI_API_KEY", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}
