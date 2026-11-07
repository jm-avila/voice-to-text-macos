import Foundation
import Testing
@testable import VoiceToTextKit

@Suite("S-004 The transcript is one clean line")
struct CleanTranscript {
    @Test("Line breaks become single spaces and the ends are trimmed", arguments: [
        ("Hello world", "Hello world"),
        ("  Hello world \n", "Hello world"),
        ("First line.\nSecond line.", "First line. Second line."),
        ("Para one.\n\nPara two.\r\nThree.", "Para one. Para two. Three."),
        ("\n \n", ""),
        ("", ""),
    ])
    func clean(raw: String, expected: String) {
        #expect(Transcript.clean(raw) == expected)
    }
}

@Suite("S-002 The HUD shows time and level")
struct HUDNumbers {
    @Test("Elapsed time reads like a clock", arguments: [
        (0.0, "0:00"), (7.9, "0:07"), (65, "1:05"), (754, "12:34"), (3723, "1:02:03"), (-3, "0:00"),
    ])
    func elapsed(seconds: Double, expected: String) {
        #expect(Elapsed.text(seconds) == expected)
    }

    @Test("The meter maps -50 to 0 dB onto 0 to 1, and clamps", arguments: [
        (Float(-160), Float(0)), (-50, 0), (-25, 0.5), (0, 1), (6, 1), (-.infinity, 0), (.nan, 0),
    ])
    func meter(decibels: Float, expected: Float) {
        #expect(Meter.level(decibels: decibels) == expected)
    }
}

@Suite("S-005 History is the bash tool's history.md")
struct History {
    let utc = TimeZone(identifier: "UTC")!

    @Test("An entry is a timestamp header, a blank line, the text, and a blank line")
    func entryFormat() {
        let date = Date(timeIntervalSince1970: 1_790_514_888)   // 2026-09-27 13:14:48 UTC
        #expect(HistoryLog.entry("Hello, this is a test.", at: date, timeZone: utc)
                == "## 2026-09-27 13:14:48\n\nHello, this is a test.\n\n")
    }

    @Test("A file the bash tool wrote reads back entry by entry, oldest first")
    func parseBashFile() {
        let file = """
        ## 2026-09-27 13:14:48

        Hello, this is a test of the voice-to-text tool.

        ## 2026-09-28 09:00:01

        Hola, esto es una prueba.

        """
        #expect(HistoryLog.parse(file) == [
            HistoryEntry(date: "2026-09-27 13:14:48", text: "Hello, this is a test of the voice-to-text tool."),
            HistoryEntry(date: "2026-09-28 09:00:01", text: "Hola, esto es una prueba."),
        ])
    }

    @Test("Writing then reading gives the same entries")
    func roundTrip() {
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let file = HistoryLog.entry("one", at: first, timeZone: utc) + HistoryLog.entry("two", at: first + 61, timeZone: utc)
        #expect(HistoryLog.parse(file).map(\.text) == ["one", "two"])
        #expect(HistoryLog.parse(file).last?.date == HistoryLog.stamp(first + 61, timeZone: utc))
    }

    @Test("Text before the first header, and an empty file, give no entries")
    func noEntries() {
        #expect(HistoryLog.parse("").isEmpty)
        #expect(HistoryLog.parse("# My notes\n\nsome text\n").isEmpty)
    }
}

@Suite("The OpenAI request")
struct Request {
    @Test("The form has the model, text format, language, and the file")
    func body() {
        var form = TranscriptionRequest(model: "gpt-4o-transcribe", language: "es")
        form.boundary = "B"
        let body = String(decoding: form.body(audio: Data("AUDIO".utf8), fileName: "r.m4a"), as: UTF8.self)
        #expect(form.contentType == "multipart/form-data; boundary=B")
        #expect(body.contains("name=\"model\"\r\n\r\ngpt-4o-transcribe\r\n"))
        #expect(body.contains("name=\"response_format\"\r\n\r\ntext\r\n"))
        #expect(body.contains("name=\"language\"\r\n\r\nes\r\n"))
        #expect(body.contains("filename=\"r.m4a\"\r\nContent-Type: audio/mp4\r\n\r\nAUDIO\r\n--B--\r\n"))
    }

    @Test("No language field when the model should detect it")
    func noLanguage() {
        let body = String(decoding: TranscriptionRequest(model: "m", language: nil).body(audio: Data(), fileName: "a"), as: UTF8.self)
        #expect(!body.contains("name=\"language\""))
    }

    @Test("A 200 body is the transcript, cleaned")
    func ok() throws {
        #expect(try TranscriptionRequest.interpret(status: 200, body: Data(" Hi there.\n".utf8)) == "Hi there.")
    }

    @Test("An error shows the API's message, not its JSON")
    func apiError() {
        let json = Data(#"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"#.utf8)
        #expect(throws: TranscriptionError.api(status: 401, message: "Incorrect API key provided")) {
            try TranscriptionRequest.interpret(status: 401, body: json)
        }
        #expect(throws: TranscriptionError.api(status: 502, message: "Bad gateway")) {
            try TranscriptionRequest.interpret(status: 502, body: Data("Bad gateway\n".utf8))
        }
        #expect(TranscriptionError.api(status: 401, message: "x").localizedDescription == "API error 401: x")
    }
}

/// Answers every request with `reply`, and keeps the last request.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reply: (status: Int, body: Data) = (200, Data())
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@Suite("S-001 and S-006 Transcribing through the API", .serialized)
struct Transcriber {
    let audio: URL = {
        let url = FileManager.default.temporaryDirectory.appending(path: "vtt-test-\(UUID().uuidString).m4a")
        try? Data("fake audio".utf8).write(to: url)
        return url
    }()

    func transcriber(key: String? = "sk-test") -> OpenAITranscriber {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return OpenAITranscriber(baseURL: URL(string: "https://api.example.test/v1")!,
                                 session: URLSession(configuration: config), key: { key })
    }

    @Test("A file over 25 MB is refused by its size, before any request")
    func tooLarge() async throws {
        let big = FileManager.default.temporaryDirectory.appending(path: "vtt-big-\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: big) }
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(TranscriptionRequest.maxBytes + 1))   // sparse: no 25 MB written
        try handle.close()
        StubProtocol.lastRequest = nil
        await #expect(throws: TranscriptionError.tooLarge(bytes: TranscriptionRequest.maxBytes + 1)) {
            try await transcriber().transcribe(big, model: "gpt-4o-transcribe", language: nil)
        }
        #expect(StubProtocol.lastRequest == nil)
    }

    @Test("It posts the file with the key and returns one clean line")
    func posts() async throws {
        StubProtocol.reply = (200, Data("Hello\nworld ".utf8))
        let text = try await transcriber().transcribe(audio, model: "gpt-4o-transcribe", language: "en")
        #expect(text == "Hello world")
        let request = try #require(StubProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://api.example.test/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = String(decoding: StubProtocol.lastBody, as: UTF8.self)
        #expect(body.contains("gpt-4o-transcribe") && body.contains("fake audio") && body.contains("name=\"language\""))
    }

    @Test("An API error carries the status and message")
    func apiError() async {
        StubProtocol.reply = (429, Data(#"{"error":{"message":"Rate limit reached"}}"#.utf8))
        await #expect(throws: TranscriptionError.api(status: 429, message: "Rate limit reached")) {
            try await transcriber().transcribe(audio, model: "m", language: nil)
        }
    }

    @Test("No key, a missing file, or an empty file fail before any request")
    func failsEarly() async throws {
        await #expect(throws: TranscriptionError.noKey) {
            try await transcriber(key: nil).transcribe(audio, model: "m", language: nil)
        }
        await #expect(throws: TranscriptionError.emptyRecording) {
            try await transcriber().transcribe(URL(fileURLWithPath: "/tmp/vtt-missing.m4a"), model: "m", language: nil)
        }
        let empty = FileManager.default.temporaryDirectory.appending(path: "vtt-empty-\(UUID().uuidString).m4a")
        try Data().write(to: empty)
        await #expect(throws: TranscriptionError.emptyRecording) {
            try await transcriber().transcribe(empty, model: "m", language: nil)
        }
    }

    @Test("OPENAI_API_KEY in the environment wins over the Keychain")
    func keyFromEnvironment() {
        #expect(APIKey.read(environment: ["OPENAI_API_KEY": "sk-env"]) == "sk-env")
    }
}

@Suite("S-007 Settings")
struct Settings {
    @Test("Settings survive a save and a load")
    func roundTrip() throws {
        let settings = DictationSettings(model: "whisper-1", language: "es", sounds: false, clickToDictate: true, hideWhenIdle: true)
        #expect(DictationSettings.decode(try settings.encoded()) == settings)
        #expect(settings.languageCode == "es")
        #expect(DictationSettings().languageCode == nil)
        // The fastest model, free and offline, unless the person picked another one.
        #expect(DictationSettings().model == Parakeet.model)
        #expect(DictationSettings.decode(Data(#"{"sounds":false}"#.utf8)).model == Parakeet.model)
    }

    @Test("Missing keys keep their defaults, and a broken file gives the defaults")
    func lenient() {
        #expect(DictationSettings.decode(Data(#"{"language":"ca"}"#.utf8)) == DictationSettings(language: "ca"))
        let old = DictationSettings.decode(Data(#"{"model":"whisper-1","sounds":false}"#.utf8))
        #expect(!old.clickToDictate && !old.hideWhenIdle)
        #expect(DictationSettings.decode(Data("not json".utf8)) == DictationSettings())
        #expect(DictationSettings.decode(nil) == DictationSettings())
    }
}

@Suite("S-011 Change the shortcut")
struct ChangeShortcut {
    @Test("The default is ⌃.")
    func standard() {
        #expect(DictationSettings().shortcut == .standard)
        #expect(Shortcut.standard.symbols == "⌃.")
        #expect(Shortcut.standard.problem == nil)
    }

    @Test("Modifiers read in Apple's order")
    func symbols() {
        let all = Shortcut(keyCode: 2, modifiers: Shortcut.command | Shortcut.shift | Shortcut.option | Shortcut.control, key: "D")
        #expect(all.symbols == "⌃⌥⇧⌘D")
        #expect(Shortcut(keyCode: 49, modifiers: Shortcut.option, key: "Space").symbols == "⌥Space")
    }

    @Test("Other bits (caps lock, the mouse button) are dropped")
    func strayBits() {
        #expect(Shortcut(keyCode: 2, modifiers: Shortcut.option | 0x0400 | 0x0080, key: "D").modifiers == Shortcut.option)
    }

    @Test("A key needs ⌃ or ⌥: ⇧ or ⌘ alone would take keys from every app", arguments: [
        (UInt32(0), false), (Shortcut.shift, false), (Shortcut.command, false), (Shortcut.command | Shortcut.shift, false),
        (Shortcut.control, true), (Shortcut.option | Shortcut.shift, true), (Shortcut.command | Shortcut.option, true),
    ])
    func needsModifier(modifiers: UInt32, ok: Bool) {
        #expect((Shortcut(keyCode: 2, modifiers: modifiers, key: "D").problem == nil) == ok)
    }

    @Test("A key with no name is refused")
    func noName() {
        #expect(Shortcut(keyCode: 2, modifiers: Shortcut.control, key: "").problem != nil)
    }

    @Test("The shortcut is saved, and an old or broken one gives ⌃.")
    func saved() throws {
        let custom = DictationSettings(shortcut: Shortcut(keyCode: 2, modifiers: Shortcut.option | Shortcut.command, key: "D"))
        #expect(DictationSettings.decode(try custom.encoded()) == custom)
        #expect(DictationSettings.decode(Data(#"{"sounds":false}"#.utf8)).shortcut == .standard)
        let shiftOnly = #"{"language":"es","shortcut":{"keyCode":2,"modifiers":512,"key":"D"}}"#
        #expect(DictationSettings.decode(Data(shiftOnly.utf8)) == DictationSettings(language: "es"))
        let capsLock = #"{"shortcut":{"keyCode":2,"modifiers":5120,"key":"D"}}"#   // ⌃ + caps lock
        #expect(DictationSettings.decode(Data(capsLock.utf8)).shortcut.modifiers == Shortcut.control)
        let wrongType = #"{"language":"es","shortcut":"ctrl+d"}"#
        #expect(DictationSettings.decode(Data(wrongType.utf8)) == DictationSettings(language: "es"))
    }

    @Test("Modifiers alone: two of them, with ⌃ or ⌥, shown with no key, saved")
    func modifiersOnly() throws {
        let optionCommand = Shortcut.modifiersOnly(Shortcut.option | Shortcut.command)
        #expect(optionCommand.isModifiersOnly && optionCommand.symbols == "⌥⌘" && optionCommand.problem == nil)
        #expect(!Shortcut.standard.isModifiersOnly)
        #expect(Shortcut.modifiersOnly(Shortcut.option).problem != nil)
        #expect(Shortcut.modifiersOnly(Shortcut.command | Shortcut.shift).problem != nil)
        let saved = DictationSettings(shortcut: optionCommand)
        #expect(DictationSettings.decode(try saved.encoded()).shortcut == optionCommand)
    }

    static let optionCommand = Shortcut.option | Shortcut.command

    /// Feeds a ⌥⌘ tap the held modifiers in turn (nil: a key or click) and gives the indexes where it fired.
    static func fires(_ steps: [UInt32?]) -> [Int] {
        var tap = ModifierTap(optionCommand)
        return steps.indices.filter { index in
            guard let held = steps[index] else { tap.otherInput(); return false }
            return tap.changed(to: held)
        }
    }

    @Test("A ⌥⌘ tap fires when both are let go, in any order")
    func tapFires() {
        #expect(Self.fires([Shortcut.option, Self.optionCommand, Shortcut.command, 0,
                            Shortcut.command, Self.optionCommand, Shortcut.option, 0]) == [3, 7])
    }

    @Test("A key, a click, or an extra modifier while held spoils the tap; the next one works")
    func tapSpoiled() {
        #expect(Self.fires([Self.optionCommand, nil, 0,   // ⌥⌘I
                            Self.optionCommand, Self.optionCommand | Shortcut.shift, Self.optionCommand, 0,
                            nil,   // typing with nothing held spoils nothing
                            Self.optionCommand, 0]) == [9])
    }

    @Test("Only one of the two, or a key first, never fires")
    func tapPartial() {
        #expect(Self.fires([Shortcut.option, 0, Shortcut.option, nil, Self.optionCommand, 0]) == [])
    }
}

@Suite("S-010 Dictate with the local model")
struct LocalModel {
    @Test("whisper-cli prints only the segments, with the voice detector, in the chosen language", arguments: [
        (String?.none, "auto"), ("", "auto"), ("es", "es"),
    ])
    func arguments(language: String?, expected: String) {
        let args = LocalWhisper.arguments(model: URL(fileURLWithPath: "/m.bin"), vad: URL(fileURLWithPath: "/v.bin"),
                                          wav: URL(fileURLWithPath: "/a.wav"), language: language)
        #expect(args == ["-m", "/m.bin", "--vad", "-vm", "/v.bin", "-f", "/a.wav", "-l", expected, "-np"])
    }

    @Test("Segments that are only a noise tag are dropped; spoken parentheses stay", arguments: [
        ("\n[00:00:00.070 --> 00:00:05.650]   The quick brown fox.\n", "The quick brown fox."),
        ("\n[00:00:00.000 --> 00:00:02.000]   [BLANK_AUDIO]\n", ""),
        ("[00:00:00.000 --> 00:00:01.000]   (music)\n[00:00:01.000 --> 00:00:03.000]   Hola, ¿qué tal?\n[00:00:03.000 --> 00:00:05.000]   [BLANK_AUDIO]\n",
         "Hola, ¿qué tal?"),
        ("[00:00:00.000 --> 00:00:01.000]   *laughs*\n[00:00:01.000 --> 00:00:02.000]   OK, first.\n[00:00:02.000 --> 00:00:03.000]   Second.",
         "OK, first. Second."),
        ("[00:00:00.000 --> 00:00:04.000]   The API (application programming interface) is down.",
         "The API (application programming interface) is down."),
    ])
    func clean(raw: String, expected: String) {
        #expect(LocalWhisper.clean(raw) == expected)
    }

    @Test("Local Whisper goes to whisper-cli, Parakeet to Parakeet, every other model to OpenAI")
    func routing() async throws {
        let router = RoutingTranscriber(openAI: Echo(name: "openai"), local: Echo(name: "local"), parakeet: Echo(name: "parakeet"))
        let file = URL(fileURLWithPath: "/a.m4a")
        #expect(try await router.transcribe(file, model: LocalWhisper.model, language: nil) == "local")
        #expect(try await router.transcribe(file, model: Parakeet.model, language: nil) == "parakeet")
        for model in DictationSettings.models where ![LocalWhisper.model, Parakeet.model].contains(model) {
            #expect(try await router.transcribe(file, model: model, language: nil) == "openai")
        }
    }

    @Test("Settings offers it by name")
    func offered() {
        #expect(DictationSettings.models.contains(LocalWhisper.model))
        #expect(DictationSettings.modelName(LocalWhisper.model) == "Whisper large-v3-turbo (on this Mac)")
        #expect(DictationSettings.models.contains(Parakeet.model))
        #expect(DictationSettings.modelName(Parakeet.model) == "Parakeet Ultra (on this Mac, fastest)")
        #expect(DictationSettings.modelName("gpt-4o-transcribe") == "OpenAI gpt-4o-transcribe")
    }

    @Test("Missing whisper.cpp or model says how to fix it")
    func missing() async throws {
        let none = URL(fileURLWithPath: "/nonexistent/x.bin")
        let audio = FileManager.default.temporaryDirectory.appending(path: "vtt-test-\(UUID()).m4a")
        try Data("x".utf8).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        await #expect(throws: TranscriptionError.noWhisperCLI) {
            try await LocalWhisperTranscriber(modelURL: none, vadURL: none, cli: { nil }).transcribe(audio, model: "", language: nil)
        }
        await #expect(throws: TranscriptionError.noLocalModel) {
            try await LocalWhisperTranscriber(modelURL: none, vadURL: none, cli: { URL(fileURLWithPath: "/usr/bin/true") })
                .transcribe(audio, model: "", language: nil)
        }
        #expect(TranscriptionError.noLocalModel.errorDescription?.contains("get-model.sh") == true)
    }
}

private struct Echo: Transcribing {
    let name: String
    func transcribe(_ file: URL, model: String, language: String?) async throws -> String { name }
}

@Suite("S-010 whisper-cli errors reach the person")
struct LocalErrors {
    @Test("An error printed with exit 0 (unknown language) is thrown, not read as silence")
    func errorWithExitZero() async throws {
        await #expect(throws: TranscriptionError.local("sh failed: error: unknown language 'zz'")) {
            try await LocalWhisperTranscriber.run(URL(fileURLWithPath: "/bin/sh"),
                                                  ["-c", "echo \"whisper_lang_id: unknown language 'zz'\" >&2; echo \"error: unknown language 'zz'\" >&2"])
        }
    }

    @Test("A tool that writes a lot to both pipes does not hang")
    func bothPipes() async throws {
        let out = try await LocalWhisperTranscriber.run(URL(fileURLWithPath: "/bin/sh"),
                                                        ["-c", "head -c 200000 /dev/zero | tr '\\0' x >&2; echo done"])
        #expect(out == "done\n")
    }
}
