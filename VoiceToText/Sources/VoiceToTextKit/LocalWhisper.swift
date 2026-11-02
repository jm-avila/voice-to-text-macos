import Foundation

/// Whisper large-v3-turbo on this Mac, through whisper.cpp's `whisper-cli`
/// (brew install whisper-cpp). No key, no network. The model is one file,
/// downloaded by `tools/get-model.sh`.
public enum LocalWhisper {
    /// The id saved in settings.json and shown by `vtt`.
    public static let model = "whisper-large-v3-turbo-local"
    static let modelFile = "ggml-large-v3-turbo.bin"
    /// In the real store even when APP_STORE moves it: one 1.6 GB copy for the app and the tests.
    public static let directory = URL.applicationSupportDirectory.appending(path: "voice-to-text/models")
    public static let modelURL = directory.appending(path: modelFile)
    /// Silero voice activity detection: without it Whisper hears "Thank you." in silence.
    public static let vadURL = directory.appending(path: "ggml-silero-v5.1.2.bin")
    /// Where Homebrew puts it. An app opened from Finder has no shell PATH.
    public static let cliPaths = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]

    public static func findCLI(_ fileManager: FileManager = .default) -> URL? {
        cliPaths.first(where: fileManager.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    /// whisper-cli's arguments: plain text on stdout, nothing else.
    public static func arguments(model: URL, vad: URL, wav: URL, language: String?) -> [String] {
        ["-m", model.path, "--vad", "-vm", vad.path, "-f", wav.path,
         "-l", language.flatMap { $0.isEmpty ? nil : $0 } ?? "auto", "-nt", "-np"]
    }

    /// whisper-cli's output as one line. Whisper marks noise as [BLANK_AUDIO],
    /// (music), and the like; those are dropped so they read as nothing heard.
    public static func clean(_ raw: String) -> String {
        Transcript.clean(raw)
            .replacing(/\[[^\]]*\]|\([^)]*\)/, with: "")
            .split(separator: " ")
            .joined(separator: " ")
    }
}

/// Runs whisper-cli on a 16 kHz mono WAV that afconvert (part of macOS)
/// makes from the recording.
public struct LocalWhisperTranscriber: Transcribing {
    public var modelURL: URL
    public var vadURL: URL
    public var cli: @Sendable () -> URL?

    public init(modelURL: URL = LocalWhisper.modelURL, vadURL: URL = LocalWhisper.vadURL,
                cli: @escaping @Sendable () -> URL? = { LocalWhisper.findCLI() }) {
        self.modelURL = modelURL
        self.vadURL = vadURL
        self.cli = cli
    }

    public func transcribe(_ file: URL, model: String, language: String?) async throws -> String {
        guard let cli = cli() else { throw TranscriptionError.noWhisperCLI }
        guard [modelURL, vadURL].allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw TranscriptionError.noLocalModel
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size > 0 else { throw TranscriptionError.emptyRecording }

        let wav = FileManager.default.temporaryDirectory.appending(path: "vtt-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        _ = try await Self.run(URL(fileURLWithPath: "/usr/bin/afconvert"),
                               ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", file.path, wav.path])
        let output = try await Self.run(cli, LocalWhisper.arguments(model: modelURL, vad: vadURL, wav: wav, language: language))
        return LocalWhisper.clean(output)
    }

    /// stdout, or the tool's own error. Off the main thread: a long recording takes seconds.
    static func run(_ tool: URL, _ arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch {
                throw TranscriptionError.local("\(tool.lastPathComponent): \(error.localizedDescription)")
            }
            // Read before waiting: a full pipe would block the tool forever.
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = Transcript.clean(String(decoding: stderr, as: UTF8.self)).suffix(200)
                throw TranscriptionError.local("\(tool.lastPathComponent) failed: \(message)")
            }
            return String(decoding: stdout, as: UTF8.self)
        }.value
    }
}

/// Sends each recording to OpenAI or to the local model, by the model chosen in Settings.
public struct RoutingTranscriber: Transcribing {
    public var openAI: Transcribing
    public var local: Transcribing

    public init(openAI: Transcribing, local: Transcribing) {
        self.openAI = openAI
        self.local = local
    }

    public func transcribe(_ file: URL, model: String, language: String?) async throws -> String {
        try await (model == LocalWhisper.model ? local : openAI).transcribe(file, model: model, language: language)
    }
}

extension LocalWhisper {
    public enum Status: String, Sendable {
        case ready, noCLI, noModel
    }

    /// Whether the local model can run: whisper-cli installed, both models downloaded.
    public static var status: Status {
        if findCLI() == nil { return .noCLI }
        return [modelURL, vadURL].allSatisfy { FileManager.default.fileExists(atPath: $0.path) } ? .ready : .noModel
    }
}
