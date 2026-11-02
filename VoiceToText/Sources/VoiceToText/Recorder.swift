import AVFoundation
import VoiceToTextKit

/// Records the microphone to a file. MicRecorder is the real one; the
/// self-test and snapshots use FakeRecorder (Fakes.swift).
nonisolated protocol AudioRecording: AnyObject, Sendable {
    /// Opens the mic and returns once audio is arriving, so the person knows
    /// when to talk. Throws when the mic fails or stays silent for `timeout`.
    func start(to url: URL, timeout: Duration) async throws
    /// Stops and closes the file. Returns its length in seconds.
    func stop() async -> TimeInterval
    /// Stops and deletes the file.
    func cancel() async
    /// The input level right now, 0 to 1, for the meter.
    func level() -> Float
}

nonisolated enum RecorderError: LocalizedError {
    case microphoneOff
    case couldNotStart
    case silent(Duration)

    var errorDescription: String? {
        switch self {
        case .microphoneOff: "Microphone access is off. Turn on VoiceToText in System Settings › Privacy & Security › Microphone"
        case .couldNotStart: "The microphone could not start"
        case .silent(let timeout): "The microphone sent no audio within \(timeout.components.seconds) s"
        }
    }
}

/// AVAudioRecorder writing AAC, mono, 16 kHz, 48 kbps (about 6 KB a second),
/// the bash tool's format. Every call to the recorder runs on one serial
/// queue: opening a cold mic can block for seconds, and the main thread
/// must keep drawing the HUD meanwhile.
nonisolated final class MicRecorder: AudioRecording, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.jmavila.voicetotext.mic")
    private var recorder: AVAudioRecorder?

    nonisolated(unsafe) static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 48_000,
    ]

    func start(to url: URL, timeout: Duration) async throws {
        // Asks the first time; answers at once after that.
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RecorderError.microphoneOff }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try? FileManager.default.removeItem(at: url)
                    let recorder = try AVAudioRecorder(url: url, settings: Self.settings)
                    recorder.isMeteringEnabled = true
                    guard recorder.record() else { throw RecorderError.couldNotStart }
                    self.recorder = recorder
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        // Live when the recorder's clock moves: audio is arriving. A cold mic
        // can take seconds; speech before this moment would be lost.
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if queue.sync(execute: { (recorder?.currentTime ?? 0) > 0 }) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        await cancel()
        throw RecorderError.silent(timeout)
    }

    func stop() async -> TimeInterval {
        await withCheckedContinuation { continuation in
            queue.async {
                let seconds = self.recorder?.currentTime ?? 0
                self.recorder?.stop()
                self.recorder = nil
                continuation.resume(returning: seconds)
            }
        }
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.recorder?.stop()
                self.recorder?.deleteRecording()
                self.recorder = nil
                continuation.resume()
            }
        }
    }

    func level() -> Float {
        queue.sync {
            guard let recorder else { return 0 }
            recorder.updateMeters()
            return Meter.level(decibels: recorder.averagePower(forChannel: 0))
        }
    }
}
