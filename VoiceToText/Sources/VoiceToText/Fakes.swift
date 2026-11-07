import AVFoundation
import Synchronization
import VoiceToTextKit

/// A recorder with no microphone, for the self-test and snapshots. It
/// "opens" after `startDelay`, writes a small file, and reports a level.
nonisolated final class FakeRecorder: AudioRecording, @unchecked Sendable {
    var startDelay: Duration = .milliseconds(100)
    var failure: Error?
    var levelValue: Float = 0.7
    /// What stop returns: how long it recorded.
    var duration: TimeInterval = 1.5
    private(set) var isRecording = false
    private var url: URL?
    private var onAudio: (@Sendable ([Float]) -> Void)?
    /// Whether the last start asked for the audio as it arrives (the local model streams).
    private(set) var streamed = false

    func start(to url: URL, timeout: Duration, onAudio: (@Sendable ([Float]) -> Void)?) async throws {
        // Like MicRecorder: the old recording goes before the mic opens.
        try? FileManager.default.removeItem(at: url)
        try? await Task.sleep(for: startDelay)
        if let failure { throw failure }
        self.url = url
        try? Data("fake audio".utf8).write(to: url)
        self.onAudio = onAudio
        streamed = onAudio != nil
        isRecording = true
    }

    /// Plays 16 kHz samples into the recording, as if spoken.
    func speak(_ samples: [Float]) {
        if isRecording { onAudio?(samples) }
    }

    func stop() async -> TimeInterval {
        isRecording = false
        onAudio = nil
        return duration
    }

    func cancel() async {
        isRecording = false
        onAudio = nil
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    func level() -> Float { isRecording ? levelValue : 0 }
}

/// A transcriber with no network. Answers `reply` after `delay` and keeps every call.
/// As the local model's server it answers `pieceReply` for each piece of a stream.
nonisolated final class FakeTranscriber: Transcribing, ChunkTranscribing, SampleTranscribing, @unchecked Sendable {
    var reply: Result<String, Error> = .success("Hello from the fake transcriber.")
    var delay: Duration = .milliseconds(100)
    private(set) var calls: [(file: URL, model: String, language: String?)] = []
    var isReady = true
    var pieceReply: Result<String, Error> = .success("Piece.")
    private(set) var pieces: [(seconds: Double, language: String?, prompt: String?)] = []

    func transcribe(wav: Data, language: String?, prompt: String?) async throws -> String {
        pieces.append((Double(wav.count - 44) / 2 / Double(WAV.rate), language, prompt))
        try? await Task.sleep(for: .milliseconds(20))
        return try pieceReply.get()
    }

    func resetPieces() { pieces = [] }

    var sampleReply: Result<String, Error> = .success("From memory.")
    private(set) var sampleCalls: [(count: Int, language: String?)] = []

    func transcribe(samples: [Float], language: String?) async throws -> String {
        sampleCalls.append((samples.count, language))
        try? await Task.sleep(for: .milliseconds(20))
        return try sampleReply.get()
    }

    func transcribe(_ file: URL, model: String, language: String?) async throws -> String {
        calls.append((file, model, language))
        try? await Task.sleep(for: delay)
        return try reply.get()
    }
}

/// A microphone that plays an audio file in real time, for measuring the
/// local model's streaming with clean speech: `APP_FAKE_MIC=<file>` with
/// `APP_STORE` (tools/latency.sh). The recording is the whole file.
nonisolated final class FileRecorder: AudioRecording, @unchecked Sendable {
    let source: URL
    private var player: Task<Void, Never>?
    private var started = ContinuousClock.now
    private let played = Mutex(0)

    init(source: URL) { self.source = source }

    func start(to url: URL, timeout: Duration, onAudio: (@Sendable ([Float]) -> Void)?) async throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: source, to: url)
        let samples = try Self.read(source)
        started = .now
        played.withLock { $0 = 0 }
        player = Task.detached {
            // 100 ms at a time, at the pace it was spoken.
            for start in stride(from: 0, to: samples.count, by: WAV.rate / 10) {
                if Task.isCancelled { return }
                let chunk = Array(samples[start ..< min(start + WAV.rate / 10, samples.count)])
                onAudio?(chunk)
                self.played.withLock { $0 += chunk.count }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() async -> TimeInterval {
        player?.cancel()
        await player?.value
        // What was played into onAudio, like the mic's samples written.
        return Double(played.withLock { $0 }) / Double(WAV.rate)
    }

    func cancel() async { player?.cancel() }

    func level() -> Float { 0.5 }

    /// 16 kHz mono floats, converted by AVAudioFile and AVAudioConverter.
    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: file.processingFormat, to: MicRecorder.format) else { return [] }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: MicRecorder.format, frameCapacity: capacity) else { return [] }
        var given = false
        _ = converter.convert(to: output, error: nil) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true
            status.pointee = .haveData
            return input
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
