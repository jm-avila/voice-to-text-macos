import Foundation
import Synchronization

/// Sends 16 kHz mono WAV audio held in memory: a piece of a dictation while
/// the person is still talking. `prompt` is the text just before it.
public protocol ChunkTranscribing: Sendable {
    /// The model is loaded right now. When false, the whole file goes at the end.
    var isReady: Bool { get }
    func transcribe(wav: Data, language: String?, prompt: String?) async throws -> String
}

/// whisper.cpp's `whisper-server` (brew install whisper-cpp), kept running
/// while the local model is selected, so a dictation does not wait for the
/// 1.6 GB model to load. One fixed port: a server that already answers there
/// (the real app's, seen from a test copy) is used as is and never stopped.
/// The one this app starts runs under a small shell that stops it when the
/// app exits, even after a crash, so no 1.6 GB copy is left behind.
public final class WhisperServer: ChunkTranscribing, Sendable {
    public static let port = 8178
    /// Where Homebrew puts it. An app opened from Finder has no shell PATH.
    public static let paths = ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]

    public let baseURL: URL
    let session: URLSession
    let modelURL: URL
    let vadURL: URL
    let executable: @Sendable () -> URL?

    private enum Phase {
        /// Not selected. A start finishing after a stop must not keep it running.
        case off
        /// Starting it, or waiting for one to answer. A second start joins this one.
        case loading(Task<String?, Never>)
        case ready
        case failed(String)
    }
    private struct State {
        /// Only a server this app started. One it found running is left alone.
        var process: Process?
        var phase = Phase.off
        /// Counts launches: an older one that resumes after a stop and a new start must not run a second server.
        var launch = 0
    }
    private let state = Mutex(State())

    public init(port: Int = WhisperServer.port, modelURL: URL = LocalWhisper.modelURL, vadURL: URL = LocalWhisper.vadURL,
                session: URLSession = .shared,
                executable: @escaping @Sendable () -> URL? = {
                    WhisperServer.paths.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
                }) {
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.session = session
        self.modelURL = modelURL
        self.vadURL = vadURL
        self.executable = executable
    }

    /// The voice detector drops silence; -nt prints the text without timestamps.
    /// The language comes with each request.
    public static func arguments(model: URL, vad: URL, port: Int) -> [String] {
        ["-m", model.path, "--vad", "-vm", vad.path, "-nt", "-l", "auto", "--host", "127.0.0.1", "--port", String(port)]
    }

    public var isReady: Bool { residency == .ready }

    public var residency: ModelResidency {
        state.withLock { state in
            switch state.phase {
            case .off: .off
            case .loading: .loading
            case .ready: .ready
            case .failed(let reason): .failed(reason)
            }
        }
    }

    /// Starts it unless one already answers. True once it answers (the model is loaded).
    /// Starts whisper-server under a shell that stops it when this app (`pid`) is gone.
    static let watchdog = """
        "$@" & server=$!
        trap 'kill $server 2>/dev/null; exit 0' TERM INT
        while kill -0 "$APP_PID" 2>/dev/null && kill -0 $server 2>/dev/null; do /bin/sleep 1; done
        kill $server 2>/dev/null
        """

    @discardableResult
    public func start() async -> Bool {
        let task = state.withLock { state -> Task<String?, Never>? in
            switch state.phase {
            case .ready: return nil
            case .loading(let task): return task
            case .off, .failed:
                state.launch += 1
                let launch = state.launch
                let task = Task { await self.launch(launch) }
                state.phase = .loading(task)
                return task
            }
        }
        guard let task else { return true }
        let failure = await task.value
        return state.withLock { state in
            // A stop, or another start after it, came first: that one decides.
            guard case .loading(let current) = state.phase, current == task else { return false }
            state.phase = failure.map(Phase.failed) ?? .ready
            return failure == nil
        }
    }

    /// Stops the server this app started and frees its memory. Safe to call from any thread.
    public func stop() {
        state.withLock { state in
            state.phase = .off
            state.process?.terminate()
            state.process = nil
        }
    }

    /// nil once it answers, else why it could not be loaded.
    private func launch(_ launch: Int) async -> String? {
        if await answers() { return nil }
        guard let executable = executable() else { return "whisper-server is not installed (brew install whisper-cpp)" }
        guard [modelURL, vadURL].allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            return "the model is not downloaded (tools/get-model.sh)"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.watchdog, "whisper-server", executable.path]
            + Self.arguments(model: modelURL, vad: vadURL, port: baseURL.port ?? Self.port)
        process.environment = ["APP_PID": String(ProcessInfo.processInfo.processIdentifier)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Under the lock: a stop that came first wins, and one that comes later finds the process.
        let launched = state.withLock { state -> String? in
            guard case .loading = state.phase, state.launch == launch else { return "stopped" }
            guard (try? process.run()) != nil else { return "whisper-server could not start" }
            state.process = process
            return nil
        }
        if let launched { return launched }
        // Loading the model takes about a second; a cold disk, longer.
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline, process.isRunning {
            if await answers() { return nil }
            try? await Task.sleep(for: .milliseconds(150))
        }
        let reason = process.isRunning ? "whisper-server took over 30 s to load the model" : "whisper-server quit while loading the model"
        // Too slow: stop it rather than keep a copy loading next to whisper-cli's.
        state.withLock { state in
            if state.process === process { state.process = nil }
        }
        process.terminate()
        return reason
    }

    /// After it stopped answering, unless another model was picked meanwhile (a stop makes it off).
    private func restartIfWanted() async {
        guard state.withLock({ if case .failed = $0.phase { true } else { false } }) else { return }
        await start()
    }

    /// Any HTTP answer: whisper-server listens only once the model is loaded.
    private func answers() async -> Bool {
        let request = URLRequest(url: baseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 0.5)
        return (try? await session.data(for: request)).map { $0.1 is HTTPURLResponse } ?? false
    }

    public func transcribe(wav: Data, language: String?, prompt: String?) async throws -> String {
        try await transcribe(wav: wav, language: language, prompt: prompt, timeout: 20)
    }

    /// `timeout` bounds a hung server: the caller then falls back to whisper-cli.
    public func transcribe(wav: Data, language: String?, prompt: String?, timeout: TimeInterval) async throws -> String {
        let form = WhisperServerRequest(language: language, prompt: prompt)
        var request = URLRequest(url: baseURL.appending(path: "inference"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, from: form.body(wav: wav))
        } catch {
            // A canceled dictation says nothing about the server: it stays loaded.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { throw error }
            // Gone (crashed, killed): whisper-cli takes over until it answers again.
            let restart = state.withLock { state in
                guard case .ready = state.phase else { return false }
                state.phase = .failed("whisper-server stopped answering: \(error.localizedDescription)")
                return true
            }
            if restart { Task { await restartIfWanted() } }
            throw TranscriptionError.local("whisper-server: \(error.localizedDescription)")
        }
        return try WhisperServerRequest.interpret(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}

/// The multipart form for whisper-server's POST /inference.
public struct WhisperServerRequest: Sendable {
    public var language: String?
    public var prompt: String?
    public var boundary = "vtt-\(UUID().uuidString)"

    public init(language: String?, prompt: String?) {
        self.language = language
        self.prompt = prompt
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public func body(wav: Data) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("response_format", "text")
        field("language", language.flatMap { $0.isEmpty ? nil : $0 } ?? "auto")
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// The text, cleaned like whisper-cli's. whisper-server reports errors as {"error": "..."}.
    public static func interpret(status: Int, body: Data) throws -> String {
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        if let message = object?["error"] as? String { throw TranscriptionError.local("whisper-server: \(message)") }
        let text = String(decoding: body, as: UTF8.self)
        guard status == 200 else { throw TranscriptionError.local("whisper-server error \(status): \(Transcript.clean(text))") }
        return LocalWhisper.clean(text)
    }
}

/// The local model for whole files (a recording, a dropped file, a retry):
/// the running server when it is ready, else whisper-cli, which loads the
/// model itself. Any server failure falls back to whisper-cli.
public struct LocalTranscriber: Transcribing {
    public var server: WhisperServer
    public var fallback: Transcribing

    public init(server: WhisperServer, fallback: Transcribing = LocalWhisperTranscriber()) {
        self.server = server
        self.fallback = fallback
    }

    public func transcribe(_ file: URL, model: String, language: String?) async throws -> String {
        guard server.isReady else { return try await fallback.transcribe(file, model: model, language: language) }
        do {
            let wav = try await LocalWhisper.wav(from: file)
            defer { try? FileManager.default.removeItem(at: wav) }
            return try await server.transcribe(wav: try Data(contentsOf: wav), language: language, prompt: nil, timeout: 600)
        } catch {
            return try await fallback.transcribe(file, model: model, language: language)
        }
    }
}
