import Foundation
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
nonisolated final class FakeTranscriber: Transcribing, ChunkTranscribing, @unchecked Sendable {
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

    func transcribe(_ file: URL, model: String, language: String?) async throws -> String {
        calls.append((file, model, language))
        try? await Task.sleep(for: delay)
        return try reply.get()
    }
}
