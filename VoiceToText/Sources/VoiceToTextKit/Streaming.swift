import Foundation

/// 16-bit PCM WAV in memory, the format whisper.cpp reads.
public enum WAV {
    public static let rate = 16_000

    /// Mono samples from -1 to 1 (louder ones are clipped) as a WAV file.
    public static func data(_ samples: [Float], rate: Int = WAV.rate) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))                     // PCM, mono
        append(UInt32(rate)); append(UInt32(rate * 2))           // sample rate, bytes a second
        append(UInt16(2)); append(UInt16(16))                    // bytes a frame, bits a sample
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        for sample in samples { append(Int16((max(-1, min(1, sample)) * 32767).rounded())) }
        return data
    }
}

/// Cuts a dictation into pieces at the pauses, as it is spoken, so each piece
/// can be transcribed while the person keeps talking. 16 kHz mono samples.
///
/// Each request to whisper costs about 430 ms whatever its length (it pads
/// to 30 s), so pieces are long: at least `minSpeech` seconds of speech, cut
/// inside a pause of `minPause` seconds. With no pause, a piece is cut at
/// `maxPiece` seconds (whisper's window is 30 s), at its quietest moment.
public struct SpeechChunker: Sendable {
    public static let frame = WAV.rate / 50   // 20 ms
    /// Quieter than this the whole way through, a tail is not sent: nothing was said.
    public static let silenceFloor: Float = -55

    public var minSpeech: Double
    public var minPause: Double
    public var maxPiece: Double

    /// Audio not sent yet, and the level of each of its 20 ms frames.
    private var pending: [Float] = []
    private var levels: [Float] = []
    /// The quietest frame heard so far: the room's noise. Speech is well above it.
    private var noise: Float?

    public init(minSpeech: Double = 4, minPause: Double = 0.6, maxPiece: Double = 25) {
        self.minSpeech = minSpeech
        self.minPause = minPause
        self.maxPiece = maxPiece
    }

    /// Adds audio. Returns the pieces now ready to send, oldest first.
    public mutating func append(_ samples: [Float]) -> [[Float]] {
        var pieces: [[Float]] = []
        pending += samples
        // Each frame that just became whole.
        while (levels.count + 1) * Self.frame <= pending.count {
            let frame = pending[levels.count * Self.frame ..< (levels.count + 1) * Self.frame]
            let level = Self.decibels(frame)
            levels.append(level)
            // The floor follows the quietest frames, and rises 1 dB a second if the room gets louder.
            noise = min(level, noise.map { $0 + 0.02 } ?? level)
            if let cut = cutPoint() {
                // A piece of silence (a long pause before speaking) is not sent.
                if levels[..<cut].contains(where: { $0 > Self.silenceFloor }) {
                    pieces.append(Array(pending[..<(cut * Self.frame)]))
                }
                pending.removeFirst(cut * Self.frame)
                levels.removeFirst(cut)
            }
        }
        return pieces
    }

    /// What is left at the end, or nil when it is only silence.
    public mutating func finish() -> [Float]? {
        defer { pending = []; levels = [] }
        let tailLevel = pending.isEmpty ? -.infinity : Self.decibels(pending[...])
        let loudest = max(levels.max() ?? -.infinity, tailLevel)
        return loudest > Self.silenceFloor ? pending : nil
    }

    /// Where to cut, in frames from the start of `pending`, or nil to keep listening.
    private func cutPoint() -> Int? {
        let framesPerSecond = 50.0
        let speech = levels.filter(isSpeech).count
        let quietRun = levels.reversed().prefix(while: { !isSpeech($0) }).count
        if Double(speech) / framesPerSecond >= minSpeech, Double(quietRun) / framesPerSecond >= minPause {
            // In the middle of the pause: both sides keep a little silence.
            return levels.count - quietRun / 2
        }
        if Double(levels.count) / framesPerSecond >= maxPiece {
            let window = Int(5 * framesPerSecond)
            let recent = levels.indices.suffix(window)
            return recent.min(by: { levels[$0] < levels[$1] }).map { $0 + 1 } ?? levels.count
        }
        return nil
    }

    /// Speech is at least 15 dB over the room's noise, and above the silence floor.
    private func isSpeech(_ level: Float) -> Bool {
        level > max((noise ?? level) + 15, Self.silenceFloor)
    }

    /// The level of some samples in dBFS: 0 is full scale, -160 is silence.
    static func decibels(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return -160 }
        let power = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        return power > 0 ? max(-160, 10 * log10(power)) : -160
    }
}

/// One dictation transcribed while it is spoken. The microphone's samples go
/// in with `append` (from any thread, in order); each piece the chunker cuts
/// is sent at once, one at a time. `finish` sends the rest and joins the text.
public final class StreamingTranscription: Sendable {
    public typealias Send = @Sendable (_ wav: Data, _ prompt: String?) async throws -> String

    private let input: AsyncStream<[Float]>.Continuation
    private let worker: Task<[String], Error>

    public init(chunker: SpeechChunker = SpeechChunker(), send: @escaping Send) {
        let (stream, input) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .unbounded)
        self.input = input
        worker = Task {
            var chunker = chunker
            var texts: [String] = []
            func transcribe(_ piece: [Float]) async throws {
                try Task.checkCancellation()
                let text = try await send(WAV.data(piece), Self.prompt(after: texts.last))
                if !text.isEmpty { texts.append(text) }
            }
            for await samples in stream {
                for piece in chunker.append(samples) { try await transcribe(piece) }
            }
            if let tail = chunker.finish() { try await transcribe(tail) }
            return texts
        }
    }

    /// Samples from the microphone, 16 kHz mono. Safe from the audio thread.
    public func append(_ samples: [Float]) {
        input.yield(samples)
    }

    /// Sends what is left once every sample is in, and returns the whole text.
    /// Throws when any piece failed: the caller sends the whole file instead.
    public func finish() async throws -> String {
        input.finish()
        return Transcript.clean(try await worker.value.joined(separator: " "))
    }

    /// Drops the dictation: no more pieces are sent, a running one is cancelled.
    public func cancel() {
        input.finish()
        worker.cancel()
    }

    /// The end of the text before a piece, so whisper keeps the spelling and
    /// the sentence going. Short: a long prompt makes whisper repeat itself.
    public static func prompt(after text: String?, limit: Int = 100) -> String? {
        guard let text, !text.isEmpty else { return nil }
        guard text.count > limit else { return text }
        let tail = text.suffix(limit)
        // Start on a whole word.
        let start = tail.firstIndex(of: " ").map { tail.index(after: $0) } ?? tail.startIndex
        return String(tail[start...])
    }
}
