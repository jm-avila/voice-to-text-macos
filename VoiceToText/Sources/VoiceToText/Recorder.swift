import AVFoundation
import VoiceToTextKit

/// Records the microphone to a file. MicRecorder is the real one; the
/// self-test and snapshots use FakeRecorder (Fakes.swift).
nonisolated protocol AudioRecording: AnyObject, Sendable {
    /// Opens the mic and returns once audio is arriving, so the person knows
    /// when to talk. Throws when the mic fails or stays silent for `timeout`.
    /// `onAudio` gets the audio as it arrives, 16 kHz mono, in order.
    func start(to url: URL, timeout: Duration, onAudio: (@Sendable ([Float]) -> Void)?) async throws
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

/// AVAudioEngine: the mic's audio, resampled to 16 kHz mono, goes to an
/// AAC file (48 kbps, about 6 KB a second, the bash tool's format) and, while
/// the local model streams, to `onAudio`. The tap only copies samples; the
/// rest runs on one serial queue, which owns every piece of state here:
/// opening a cold mic can block for seconds, and the main thread must keep
/// drawing the HUD meanwhile.
nonisolated final class MicRecorder: AudioRecording, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.jmavila.voicetotext.mic")
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var onAudio: (@Sendable ([Float]) -> Void)?
    /// Samples written, at 16 kHz.
    private var written: AVAudioFramePosition = 0
    private var lastLevel: Float = 0
    private var configurationObserver: NSObjectProtocol?

    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    nonisolated(unsafe) static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 48_000,
    ]

    func start(to url: URL, timeout: Duration, onAudio: (@Sendable ([Float]) -> Void)?) async throws {
        // Asks the first time; answers at once after that.
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RecorderError.microphoneOff }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try? FileManager.default.removeItem(at: url)
                    self.file = try AVAudioFile(forWriting: url, settings: Self.settings,
                                                commonFormat: .pcmFormatFloat32, interleaved: false)
                    self.onAudio = onAudio
                    self.written = 0
                    let engine = AVAudioEngine()
                    self.engine = engine
                    try self.listen(engine)
                    // A headset plugged in or out stops the engine: listen to the new mic.
                    self.configurationObserver = NotificationCenter.default.addObserver(
                        forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
                        // Removed in close(), so holding the recorder here is not a cycle.
                        self.queue.async { self.restart() }
                    }
                    continuation.resume()
                } catch {
                    self.close()
                    continuation.resume(throwing: error)
                }
            }
        }
        // Live once the first samples are written. A cold mic can take seconds;
        // speech before this moment would be lost.
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if queue.sync(execute: { written > 0 }) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        await cancel()
        throw RecorderError.silent(timeout)
    }

    /// On the queue: a tap in the mic's own format, and a converter from it to 16 kHz mono.
    private func listen(_ engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: Self.format) else { throw RecorderError.couldNotStart }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 1_600, format: format) { [weak self] buffer, _ in
            // The audio thread: copy the first channel and leave.
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            queue.async { self.write(samples, format: mono) }
        }
        engine.prepare()
        try engine.start()
    }

    private func restart() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // A new mic that will not start ends the recording; the file keeps what was said.
        if (try? listen(engine)) == nil { engine.inputNode.removeTap(onBus: 0) }
    }

    /// On the queue: resample, append to the file, hand to the stream, measure the level.
    private func write(_ samples: [Float], format: AVAudioFormat) {
        guard let file, let converter, converter.inputFormat == format, !samples.isEmpty,
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let capacity = AVAudioFrameCount(Double(samples.count) * Self.format.sampleRate / format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
        var given = false
        let status = converter.convert(to: output, error: nil) { _, inputStatus in
            if given { inputStatus.pointee = .noDataNow; return nil }
            given = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return }
        try? file.write(from: output)
        written += AVAudioFramePosition(output.frameLength)
        let converted = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        onAudio?(converted)
        let power = converted.reduce(Float(0)) { $0 + $1 * $1 } / Float(converted.count)
        lastLevel = Meter.level(decibels: power > 0 ? 10 * log10(power) : -160)
    }

    /// On the queue: no more audio. Dropping the file finishes it on disk.
    private func close() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        file = nil
        converter = nil
        onAudio = nil
        lastLevel = 0
    }

    func stop() async -> TimeInterval {
        await withCheckedContinuation { continuation in
            queue.async {
                // No tap runs after removeTap returns, but its last samples are
                // queued behind this block: close after them, from the back of the queue.
                self.engine?.inputNode.removeTap(onBus: 0)
                self.engine?.stop()
                self.queue.async {
                    let seconds = Double(self.written) / Self.format.sampleRate
                    self.close()
                    continuation.resume(returning: seconds)
                }
            }
        }
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            queue.async {
                let url = self.file?.url
                self.close()
                if let url { try? FileManager.default.removeItem(at: url) }
                continuation.resume()
            }
        }
    }

    func level() -> Float {
        queue.sync { lastLevel }
    }
}
