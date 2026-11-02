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

    func start(to url: URL, timeout: Duration) async throws {
        // Like MicRecorder: the old recording goes before the mic opens.
        try? FileManager.default.removeItem(at: url)
        try? await Task.sleep(for: startDelay)
        if let failure { throw failure }
        self.url = url
        try? Data("fake audio".utf8).write(to: url)
        isRecording = true
    }

    func stop() async -> TimeInterval {
        isRecording = false
        return duration
    }

    func cancel() async {
        isRecording = false
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    func level() -> Float { isRecording ? levelValue : 0 }
}

/// A transcriber with no network. Answers `reply` after `delay` and keeps every call.
nonisolated final class FakeTranscriber: Transcribing, @unchecked Sendable {
    var reply: Result<String, Error> = .success("Hello from the fake transcriber.")
    var delay: Duration = .milliseconds(100)
    private(set) var calls: [(file: URL, model: String, language: String?)] = []

    func transcribe(_ file: URL, model: String, language: String?) async throws -> String {
        calls.append((file, model, language))
        try? await Task.sleep(for: delay)
        return try reply.get()
    }
}
