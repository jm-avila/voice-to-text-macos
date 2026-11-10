import Foundation
import Synchronization
import Testing
@testable import VoiceToTextKit

/// Test audio at 16 kHz: speech is a loud tone, a pause is a faint one.
private enum Audio {
    static func tone(_ seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int(seconds * Double(WAV.rate))).map { amplitude * sin(Float($0) * 2 * .pi * 220 / Float(WAV.rate)) }
    }
    static func speech(_ seconds: Double) -> [Float] { tone(seconds, amplitude: 0.3) }
    static func pause(_ seconds: Double) -> [Float] { tone(seconds, amplitude: 0.0005) }

    /// Fed 100 ms at a time, like the microphone.
    static func feed(_ samples: [Float], into chunker: inout SpeechChunker) -> [[Float]] {
        stride(from: 0, to: samples.count, by: 1600).flatMap {
            chunker.append(Array(samples[$0 ..< min($0 + 1600, samples.count)]))
        }
    }
}

@Suite("S-014 Pieces are cut at the pauses")
struct Chunking {
    @Test("A pause after 4 s of speech cuts a piece; the rest waits for the end")
    func cutsAtPause() throws {
        var chunker = SpeechChunker()
        let audio = Audio.speech(5) + Audio.pause(1) + Audio.speech(2)
        let pieces = Audio.feed(audio, into: &chunker)
        #expect(pieces.count == 1)
        let first = try #require(pieces.first)
        // Cut inside the pause: after the speech, before the next word.
        #expect(first.count > 5 * WAV.rate && first.count < 6 * WAV.rate)
        let rest = chunker.finish()
        let tail = try #require(rest)
        #expect(first.count + tail.count == audio.count)
    }

    @Test("Digital zeros while the mic opens do not hide the pauses")
    func zerosFirst() {
        var chunker = SpeechChunker()
        let audio = [Float](repeating: 0, count: WAV.rate / 3) + Audio.speech(5) + Audio.pause(1) + Audio.speech(1)
        #expect(Audio.feed(audio, into: &chunker).count == 1)
    }

    @Test("A noisy room: pauses 15 dB under the voice are found")
    func noisyRoom() {
        var chunker = SpeechChunker()
        let audio = Audio.tone(5, amplitude: 0.05) + Audio.tone(1, amplitude: 0.009) + Audio.tone(1, amplitude: 0.05)
        #expect(Audio.feed(audio, into: &chunker).count == 1)
    }

    @Test("Less than 4 s of speech before a pause is not cut")
    func shortSpeechWaits() {
        var chunker = SpeechChunker()
        #expect(Audio.feed(Audio.speech(3) + Audio.pause(1), into: &chunker).isEmpty)
        #expect(chunker.finish()?.count == 4 * WAV.rate)
    }

    @Test("A short breath (under 0.6 s) is not a pause")
    func breathIsNotAPause() {
        var chunker = SpeechChunker()
        #expect(Audio.feed(Audio.speech(5) + Audio.pause(0.4) + Audio.speech(2), into: &chunker).isEmpty)
    }

    @Test("Talking with no pause is cut at 25 s, inside whisper's 30 s window")
    func forcedCut() {
        var chunker = SpeechChunker()
        let pieces = Audio.feed(Audio.speech(30), into: &chunker)
        #expect(pieces.count == 1)
        #expect(pieces.allSatisfy { $0.count <= 25 * WAV.rate && $0.count >= 20 * WAV.rate })
    }

    @Test("Silence is never sent, as a piece or as the tail")
    func silenceDropped() {
        var chunker = SpeechChunker()
        #expect(Audio.feed(Audio.pause(30), into: &chunker).isEmpty)
        #expect(chunker.finish() == nil)
    }

    @Test("A quiet speaker still gets a tail: only true silence is dropped")
    func quietTailKept() {
        var chunker = SpeechChunker()
        _ = Audio.feed(Audio.tone(2, amplitude: 0.01), into: &chunker)   // about -43 dBFS
        #expect(chunker.finish()?.count == 2 * WAV.rate)
    }
}

@Suite("S-014 WAV in memory")
struct WAVFile {
    @Test("A 44-byte header for 16 kHz mono 16-bit, then the samples, clipped")
    func header() {
        let data = WAV.data([0, 1, -1, 2])
        #expect(data.count == 44 + 8)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
        let rate = data[24..<28].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        #expect(rate == 16_000)
        let samples = stride(from: 44, to: 52, by: 2).map { Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8) }
        #expect(samples == [0, 32767, -32767, 32767])
    }
}

/// A transcriber for pieces that answers "piece 1", "piece 2"… and keeps what it got.
private final class Pieces: Sendable {
    let log = Mutex<[(seconds: Double, prompt: String?)]>([])
    let failOn: Int?

    init(failOn: Int? = nil) { self.failOn = failOn }

    var send: StreamingTranscription.Send {
        { wav, prompt in
            let count = self.log.withLock { log in
                log.append((Double(wav.count - 44) / 2 / Double(WAV.rate), prompt))
                return log.count
            }
            if count == self.failOn { throw TranscriptionError.local("boom") }
            return "piece \(count)."
        }
    }
}

@Suite("S-014 Transcribed while you talk")
struct Streaming {
    @Test("Pieces go out during the dictation, in order, each with the text before it")
    func streams() async throws {
        let pieces = Pieces()
        let stream = StreamingTranscription(send: pieces.send)
        for part in [Audio.speech(5), Audio.pause(1), Audio.speech(5), Audio.pause(1)] {
            stream.append(part)
        }
        // Both pauses were heard before the end: two pieces are already out.
        try await Task.sleep(for: .milliseconds(300))
        #expect(pieces.log.withLock { $0.count } == 2)
        stream.append(Audio.speech(1))
        #expect(try await stream.finish() == "piece 1. piece 2. piece 3.")
        let log = pieces.log.withLock { $0 }
        #expect(log.map(\.prompt) == [nil, "piece 1.", "piece 2."])
        #expect(abs(log.map(\.seconds).reduce(0, +) - 13) < 0.01)   // every sample sent once
    }

    @Test("A failed piece fails the whole stream, so the file is sent instead")
    func failure() async {
        let stream = StreamingTranscription(send: Pieces(failOn: 1).send)
        stream.append(Audio.speech(5) + Audio.pause(1) + Audio.speech(1))
        await #expect(throws: TranscriptionError.local("boom")) { try await stream.finish() }
    }

    @Test("Cancel sends nothing more")
    func cancel() async throws {
        let pieces = Pieces()
        let stream = StreamingTranscription(send: pieces.send)
        stream.cancel()
        stream.append(Audio.speech(5) + Audio.pause(1))
        try await Task.sleep(for: .milliseconds(100))
        #expect(pieces.log.withLock { $0.isEmpty })
    }

    @Test("The prompt is the last 100 characters at most, from a whole word")
    func prompt() {
        #expect(StreamingTranscription.prompt(after: nil) == nil)
        #expect(StreamingTranscription.prompt(after: "Hola.") == "Hola.")
        let long = String(repeating: "palabra ", count: 30) + "fin."
        let prompt = StreamingTranscription.prompt(after: long) ?? ""
        #expect(prompt.count <= 100 && prompt.hasPrefix("palabra") && prompt.hasSuffix("fin."))
    }
}

/// Answers whisper-server's requests: GET / with 200, POST /inference with `reply`.
final class ServerStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reply: (status: Int, body: Data) = (200, Data())
    nonisolated(unsafe) static var down = false
    nonisolated(unsafe) static var lastBody = Data()
    /// GET / answers after 300 ms: a server still loading.
    nonisolated(unsafe) static var slowAnswer = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if Self.down { return client!.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)) }
        if Self.slowAnswer, request.url?.path != "/inference" {
            Self.slowAnswer = false
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { self.answer() }
            return
        }
        answer()
    }

    private func answer() {
        let inference = request.url?.path == "/inference"
        if inference { Self.lastBody = request.httpBody ?? request.httpBodyStream.map(StubProtocol.read) ?? Data() }
        let status = inference ? Self.reply.status : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: inference ? Self.reply.body : Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ServerStub.self]
        return URLSession(configuration: config)
    }
}

@Suite("S-014 The local model stays loaded", .serialized)
struct ResidentModel {
    @Test("whisper-server loads the model once, with the voice detector, no timestamps, on localhost")
    func arguments() {
        let args = WhisperServer.arguments(model: URL(fileURLWithPath: "/m.bin"), vad: URL(fileURLWithPath: "/v.bin"), port: 8178)
        #expect(args == ["-m", "/m.bin", "--vad", "-vm", "/v.bin", "-nt", "-l", "auto", "--host", "127.0.0.1", "--port", "8178"])
    }

    @Test("Each request carries the language (or auto), the prompt, and the WAV")
    func form() {
        let body = String(decoding: WhisperServerRequest(language: "es", prompt: "Hola.").body(wav: Data("RIFFwav".utf8)), as: UTF8.self)
        #expect(body.contains("name=\"language\"\r\n\r\nes\r\n") && body.contains("name=\"prompt\"\r\n\r\nHola.\r\n")
                && body.contains("RIFFwav") && body.contains("name=\"response_format\"\r\n\r\ntext\r\n"))
        let auto = String(decoding: WhisperServerRequest(language: nil, prompt: nil).body(wav: Data()), as: UTF8.self)
        #expect(auto.contains("name=\"language\"\r\n\r\nauto\r\n") && !auto.contains("name=\"prompt\""))
    }

    @Test("Its answer is cleaned like whisper-cli's; an error is thrown", arguments: [
        (200, " Hola, ¿qué tal?\n [BLANK_AUDIO]\n", "Hola, ¿qué tal?"),
    ])
    func interpret(status: Int, body: String, expected: String) throws {
        #expect(try WhisperServerRequest.interpret(status: status, body: Data(body.utf8)) == expected)
        #expect(throws: TranscriptionError.local("whisper-server: failed to read audio")) {
            try WhisperServerRequest.interpret(status: 200, body: Data(#"{"error":"failed to read audio"}"#.utf8))
        }
    }

    @Test("A server already answering on the port is used; none answering and no binary is not ready")
    func start() async {
        ServerStub.down = false
        let found = WhisperServer(session: ServerStub.session, executable: { nil })
        #expect(await found.start() && found.isReady)
        ServerStub.down = true
        let none = WhisperServer(session: ServerStub.session, executable: { nil })
        #expect(await none.start() == false && !none.isReady)
        ServerStub.down = false
    }

    @Test("A stop while it starts wins: the server is not ready afterwards")
    func stopWhileStarting() async {
        ServerStub.down = false
        let server = WhisperServer(session: ServerStub.session, executable: { nil })
        ServerStub.slowAnswer = true
        defer { ServerStub.slowAnswer = false }
        let started = Task { await server.start() }
        try? await Task.sleep(for: .milliseconds(100))   // it is waiting for the server to answer
        server.stop()
        #expect(await started.value == false && !server.isReady)
    }

    @Test("A canceled dictation leaves the server loaded: the next one still streams")
    func cancelKeepsItLoaded() async {
        ServerStub.down = false
        let server = WhisperServer(session: ServerStub.session, executable: { nil })
        await server.start()
        let piece = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await server.transcribe(wav: WAV.data(Audio.speech(1)), language: "es", prompt: nil)
        }
        _ = try? await piece.value
        #expect(server.isReady && server.residency == .ready)
    }

    @Test("Its residency: loaded, failed with the reason, or off after a stop")
    func residency() async {
        ServerStub.down = false
        let found = WhisperServer(session: ServerStub.session, executable: { nil })
        #expect(found.residency == .off)
        await found.start()
        #expect(found.residency == .ready)
        found.stop()
        #expect(found.residency == .off)
        ServerStub.down = true
        defer { ServerStub.down = false }
        let none = WhisperServer(session: ServerStub.session, executable: { nil })
        await none.start()
        #expect(none.residency == .failed("whisper-server is not installed (brew install whisper-cpp)"))
        // A request to a server that went away: not loaded any more, and it says why.
        ServerStub.down = false
        await found.start()
        ServerStub.down = true
        _ = try? await found.transcribe(wav: WAV.data(Audio.speech(1)), language: "es", prompt: nil)
        #expect(!found.isReady)
        if case .ready = found.residency { Issue.record("still ready after the server went away") }
    }

    @Test("Whole files go to the server when it is ready, else to whisper-cli; a failure falls back")
    func routing() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "vtt-server-\(UUID()).wav")
        try WAV.data(Audio.speech(1)).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let server = WhisperServer(session: ServerStub.session, executable: { nil })
        let local = LocalTranscriber(server: server, fallback: Fallback())
        #expect(try await local.transcribe(file, model: LocalWhisper.model, language: "es") == "whisper-cli")
        ServerStub.down = false
        await server.start()
        ServerStub.reply = (200, Data(" Desde el servidor.\n".utf8))
        #expect(try await local.transcribe(file, model: LocalWhisper.model, language: "es") == "Desde el servidor.")
        #expect(String(decoding: ServerStub.lastBody, as: UTF8.self).contains("RIFF"))
        ServerStub.reply = (500, Data("crash".utf8))
        #expect(try await local.transcribe(file, model: LocalWhisper.model, language: "es") == "whisper-cli")
    }
}

private struct Fallback: Transcribing {
    func transcribe(_ file: URL, model: String, language: String?) async throws -> String { "whisper-cli" }
}
