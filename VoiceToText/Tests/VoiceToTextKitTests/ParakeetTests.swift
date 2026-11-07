import FluidAudio
import Foundation
import Testing
@testable import VoiceToTextKit

@Suite("Parakeet")
struct ParakeetTests {
    @Test("The language is only a script hint; none or an unknown code is no hint")
    func hint() {
        #expect(Parakeet.hint("es")?.rawValue == "es")
        #expect(Parakeet.hint("en")?.rawValue == "en")
        #expect(Parakeet.hint(nil) == nil)
        #expect(Parakeet.hint("xx") == nil)
    }

    @Test("An empty recording fails at once, without loading the model")
    func empty() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "vtt-parakeet-\(UUID()).m4a")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let parakeet = ParakeetTranscriber()
        await #expect(throws: TranscriptionError.emptyRecording) {
            try await parakeet.transcribe(file, model: Parakeet.model, language: "es")
        }
        #expect(!parakeet.isLoaded && !parakeet.isLoading)
    }

    @Test("The buffer keeps samples in order from any thread and empties when taken")
    func buffer() async {
        let buffer = SampleBuffer()
        buffer.append([1, 2])
        await Task.detached { buffer.append([3]) }.value
        #expect(buffer.take() == [1, 2, 3])
        #expect(buffer.take().isEmpty)
    }

    @Test("Past its limit the buffer lets go of everything, so a very long dictation goes through the file")
    func limit() {
        let buffer = SampleBuffer(limit: 4)
        buffer.append([1, 2, 3])
        buffer.append([4, 5])
        buffer.append([6])
        #expect(buffer.take().isEmpty)
    }

    @Test("Samples from memory: under a quarter second is nothing heard, without loading the model")
    func tooShort() async throws {
        let parakeet = ParakeetTranscriber()
        #expect(try await parakeet.transcribe(samples: [Float](repeating: 0.1, count: 3_000), language: "es") == "")
        #expect(!parakeet.isLoaded && !parakeet.isLoading)
    }

    /// The real model, when it is downloaded (pick Parakeet once in Settings). `say` makes the speech.
    @Test("Spanish and English come back in their own language, a short word too, and unload frees it",
          .enabled(if: Parakeet.status == .ready))
    func real() async throws {
        let parakeet = ParakeetTranscriber()
        try await parakeet.load()   // what picking it in Settings does
        for (voice, text, language, expected) in [
            // Not Mónica: through Process the accented name picks a voice that is not Spanish.
            ("Paulina", "Hola, esto es una prueba de dictado.", "es", "Hola, esto es una prueba de dictado."),
            // English with Español chosen: Whisper translates it, Parakeet must not.
            ("Samantha", "This is a quick dictation test.", "es", "This is a quick dictation test."),
            ("Paulina", "Sí, claro.", "es", "Sí, claro."),
        ] {
            let file = try Self.say(voice, text)
            defer { try? FileManager.default.removeItem(at: file) }
            let heard = try await parakeet.transcribe(file, model: Parakeet.model, language: language)
            #expect(heard == expected)
        }
        // From memory, the recorder's samples: the same text as from the file.
        let memory = try Self.say("Paulina", "Hola, esto es una prueba de dictado.")
        defer { try? FileManager.default.removeItem(at: memory) }
        let samples = try AudioConverter().resampleAudioFile(path: memory.path)
        #expect(try await parakeet.transcribe(samples: samples, language: "es") == "Hola, esto es una prueba de dictado.")
        #expect(parakeet.isLoaded)
        // Another model picked while a dictation is being transcribed: that dictation still comes back.
        let file = try Self.say("Paulina", "Mañana compramos pan y leche en el mercado.")
        defer { try? FileManager.default.removeItem(at: file) }
        let running = Task { try await parakeet.transcribe(file, model: Parakeet.model, language: "es") }
        try await Task.sleep(for: .milliseconds(5))
        parakeet.unload()
        #expect(try await running.value.contains("mercado"))
        // A transcription after the switch does not keep the model loaded.
        #expect(try await parakeet.transcribe(file, model: Parakeet.model, language: "es").contains("mercado"))
        #expect(!parakeet.isLoaded)
    }

    static func say(_ voice: String, _ text: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "vtt-say-\(UUID()).m4a")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "-o", file.path, "--file-format=m4af", "--data-format=aac", text]
        try say.run()
        say.waitUntilExit()
        return file
    }
}
