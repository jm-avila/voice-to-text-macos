import AppKit
import VoiceToTextKit

/// Self-test for agents: runs the app's real functions with a fake mic, a
/// fake transcriber, and a private pasteboard (never your clipboard, mic,
/// or OpenAI account), on a test store. Prints PASS or FAIL per check and
/// quits with exit code 0 or 1.
///   APP_STORE=/tmp/VoiceToText-self.store ~/Applications/VoiceToText.app/Contents/MacOS/VoiceToText --selftest
/// (tools/selftest.sh does this.) Add a check for every story with logic.
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }
    /// Read by AppDelegate.applicationWillTerminate.
    static var exitCode: Int32 = 0
    private static var failures = 0
    private static var count = 0

    /// True when the self-test runs (the app does not start normally).
    static func runIfRequested(services: Services) -> Bool {
        guard requested else { return false }
        // Print each line at once, so a crash keeps the lines before it.
        setvbuf(stdout, nil, _IOLBF, 0)
        guard Store.isOverridden else {
            print("SELFTEST refused: set APP_STORE to a folder in /tmp")
            finish(code: 1)
            return true
        }
        Task {
            await run(services)
            services.dictation.paster.pasteboard.releaseGlobally()
            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
        return true
    }

    private static func run(_ services: Services) async {
        let dictation = services.dictation
        guard let recorder = dictation.recorder as? FakeRecorder,
              let transcriber = dictation.transcriber as? FakeTranscriber else {
            check("the self-test runs with the fake mic and transcriber", false)
            return
        }
        let paster = dictation.paster
        let store = services.store
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        func historyFile() -> String { (try? String(contentsOf: store.historyURL, encoding: .utf8)) ?? "" }
        paster.canPaste = { true }

        // S-001 Press, talk, press: the text is pasted where the cursor is.
        recorder.startDelay = .milliseconds(300)
        transcriber.reply = .success("Hello from the self-test.")
        let starting = Task { await dictation.toggle() }
        await wait(0.1)
        check("S-002 the first press shows the mic opening", dictation.state == .starting)
        check("S-002 the HUD shows while the mic opens", services.hud.isVisible)
        check("S-002 the menu bar shows a dimmed mic", services.statusItem.symbolName == "mic")
        await dictation.toggle()
        check("S-003 a press while the mic opens is ignored", dictation.state == .starting)
        await starting.value
        check("S-002 once the mic is live, it records", dictation.state.name == "recording")
        check("S-002 Tink plays when the mic is live", dictation.sounds.lastCue == .start)
        check("S-002 the menu bar shows a red mic", services.statusItem.symbolName == "mic.fill")
        check("the HUD never takes focus or clicks",
              services.hud.window?.isKeyWindow == false && services.hud.window?.ignoresMouseEvents == true)

        transcriber.delay = .milliseconds(300)
        let stopping = Task { await dictation.toggle() }
        await wait(0.1)
        check("S-002 the second press transcribes", dictation.state == .transcribing)
        check("S-002 Pop plays on the second press", dictation.sounds.lastCue == .stop)
        check("S-002 the menu bar shows an ellipsis", services.statusItem.symbolName == "ellipsis")
        await dictation.toggle()
        check("S-003 a press while transcribing is ignored", dictation.state == .transcribing)
        await stopping.value
        check("S-001 the text is pasted", paster.last?.text == "Hello from the self-test." && paster.last?.pasted == true)
        check("S-004 the text stays on the clipboard", paster.pasteboard.string(forType: .string) == "Hello from the self-test.")
        check("S-001 the HUD says Pasted", dictation.notice == .pasted && services.hud.isVisible)
        check("S-001 back to ready", dictation.state == .idle && services.statusItem.symbolName == "waveform")
        check("the transcriber got the recording, the model, and no language",
              transcriber.calls.last?.file == store.recordingURL && transcriber.calls.last?.model == "gpt-4o-transcribe"
                && transcriber.calls.last?.language == nil)
        await wait(1.5)
        check("the HUD hides after the notice", !services.hud.isVisible)

        // S-005 History, in the bash tool's format.
        let entries = HistoryLog.parse(historyFile())
        check("S-005 the transcript is saved to history.md", entries.last?.text == "Hello from the self-test.")
        check("S-005 with a timestamp header", historyFile().hasPrefix("## 20") && historyFile().contains("\n\nHello from the self-test.\n\n"))
        check("S-005 the menu's history matches the file", dictation.history == entries)

        // Without Accessibility the text is only copied.
        paster.canPaste = { false }
        transcriber.delay = .milliseconds(50)
        transcriber.reply = .success("Copied, not pasted.")
        try? await dictation.start()
        _ = try? await dictation.stop(paste: true)
        check("without Accessibility the text is copied and the HUD says so",
              paster.last?.pasted == false && dictation.notice == .copied
                && paster.pasteboard.string(forType: .string) == "Copied, not pasted.")
        paster.canPaste = { true }

        // S-004 Nothing heard: no paste, no history.
        let saved = dictation.history.count
        transcriber.reply = .success("")
        paster.pasteboard.clearContents()
        try? await dictation.start()
        let silent = try? await dictation.stop(paste: true)
        check("S-004 nothing heard pastes and saves nothing",
              silent == "" && dictation.notice == .nothingHeard && dictation.history.count == saved
                && paster.pasteboard.string(forType: .string) == nil)

        // S-006 Errors show, and the recording is kept for a retry.
        transcriber.reply = .failure(TranscriptionError.api(status: 401, message: "Incorrect API key provided"))
        try? await dictation.start()
        _ = try? await dictation.stop(paste: true)
        check("S-006 an API error shows in the HUD", dictation.notice == .error("API error 401: Incorrect API key provided"))
        check("S-006 and goes back to ready, with a retry", dictation.state == .idle && dictation.canRetry
                && FileManager.default.fileExists(atPath: store.recordingURL.path))
        transcriber.reply = .success("Second try worked.")
        let retried = try? await dictation.retry(paste: true)
        check("S-006 retry sends the kept recording and pastes", retried == "Second try worked." && !dictation.canRetry
                && paster.last?.text == "Second try worked.")

        recorder.failure = RecorderError.silent(.seconds(10))
        let micFailed = (try? await dictation.start()) == nil
        check("S-006 a mic that sends no audio shows an error and goes back to ready",
              micFailed && dictation.state == .idle && dictation.lastError?.contains("no audio") == true)
        recorder.failure = nil

        // S-009 Cancel throws the recording away.
        let calls = transcriber.calls.count
        try? await dictation.start()
        await dictation.cancel()
        check("S-009 cancel stops without transcribing", dictation.state == .idle && dictation.notice == .canceled
                && transcriber.calls.count == calls && !FileManager.default.fileExists(atPath: store.recordingURL.path))
        recorder.startDelay = .milliseconds(300)
        let opening = Task { try await dictation.start() }
        await wait(0.1)
        await dictation.cancel()
        let openedThenCanceled = (try? await opening.value) == nil
        check("S-009 cancel while the mic opens stops it once open", openedThenCanceled && dictation.state == .idle && !recorder.isRecording)
        recorder.startDelay = .milliseconds(50)

        // S-007 Settings are saved and used.
        dictation.settings.language = "es"
        dictation.settings.model = "gpt-4o-mini-transcribe"
        check("S-007 settings are saved", Store(directory: store.directory).loadSettings()
                == DictationSettings(model: "gpt-4o-mini-transcribe", language: "es", sounds: true))
        dictation.settings.sounds = false
        let plays = dictation.sounds.plays
        try? await dictation.start()
        _ = try? await dictation.stop(paste: false)
        check("S-007 with sounds off, no cue plays", dictation.sounds.plays == plays)
        check("S-007 the model and language go to the transcriber",
              transcriber.calls.last?.model == "gpt-4o-mini-transcribe" && transcriber.calls.last?.language == "es")
        dictation.settings = DictationSettings()

        // S-008 Agent commands, through the same router the socket uses.
        func agent(_ command: String, _ args: [String: String] = [:]) async -> JSONObject {
            let reply = await AgentRouter.handle(JSON.data(["command": command, "args": args]))
            return (try? JSONSerialization.jsonObject(with: reply) as? JSONObject) ?? [:]
        }
        func result(_ reply: JSONObject) -> JSONObject? { reply["result"] as? JSONObject }
        let status = result(await agent("status"))
        check("S-008 status reports the state and settings",
              status?["state"] as? String == "idle" && status?["model"] as? String == "gpt-4o-transcribe" && status?["language"] as? String == "auto")
        transcriber.reply = .success("Said through the CLI.")
        let started = result(await agent("start"))
        check("S-008 start returns once recording", started?["state"] as? String == "recording" && dictation.state.name == "recording")
        let busy = await agent("start")
        check("S-008 a second start says already recording", (busy["error"] as? JSONObject)?["message"] as? String == "already recording")
        paster.pasteboard.clearContents()
        let stopped = result(await agent("stop"))
        check("S-008 stop returns the text and saves it, without pasting",
              stopped?["text"] as? String == "Said through the CLI." && dictation.history.last?.text == "Said through the CLI."
                && paster.pasteboard.string(forType: .string) == nil)
        let notRecording = await agent("stop")
        check("S-008 stop when idle says not recording", (notRecording["error"] as? JSONObject)?["message"] as? String == "not recording")
        let file = store.directory.appending(path: "memo.m4a")
        try? Data("memo".utf8).write(to: file)
        transcriber.reply = .success("A memo from a file.")
        let before = dictation.history.count
        let transcribed = result(await agent("transcribe", ["file": file.path]))
        check("S-008 transcribe reads any file and saves nothing",
              transcribed?["text"] as? String == "A memo from a file." && dictation.history.count == before
                && transcriber.calls.last?.file == file)
        let missing = await agent("transcribe", ["file": "/tmp/no-such-file.m4a"])
        check("S-008 a missing file is not_found", (missing["error"] as? JSONObject)?["code"] as? String == "not_found")
        let listed = result(await agent("history list", ["limit": "2"]))
        let listedEntries = listed?["entries"] as? [JSONObject]
        check("S-008 history list is newest first", listedEntries?.count == 2
                && listedEntries?.first?["text"] as? String == "Said through the CLI." && listed?["total"] as? Int == dictation.history.count)
        let badModel = await agent("settings update", ["model": "gpt-9", "sounds": "false"])
        check("S-008 a bad model changes no other setting",
              (badModel["error"] as? JSONObject)?["code"] as? String == "usage" && dictation.settings.sounds)
        let updated = result(await agent("settings update", ["language": "ES", "sounds": "false"]))
        check("S-008 settings update changes only what it is given",
              updated?["language"] as? String == "es" && dictation.settings.sounds == false && dictation.settings.model == "gpt-4o-transcribe")
        _ = await agent("settings update", ["language": "auto", "sounds": "true"])
        check("S-008 language auto clears it", dictation.settings.languageCode == nil)

        // Every SF Symbol the app uses exists.
        let symbols = ["waveform", "mic", "mic.fill", "ellipsis", "checkmark.circle.fill", "doc.on.clipboard", "ear",
                       "xmark.circle", "xmark.circle.fill", "exclamationmark.triangle.fill"]
        let missingSymbols = symbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        check("every SF Symbol exists", missingSymbols.isEmpty, missingSymbols.joined(separator: ", "))
        check("the system sounds exist", NSSound(named: "Tink") != nil && NSSound(named: "Pop") != nil)

        // S-007 Settings opens, and closing it keeps the app running.
        services.settingsWindow.show()
        await wait(0.5)
        check("Settings opens", services.settingsWindow.isVisible)
        services.settingsWindow.close()
        check("Settings closes, and the app keeps running", !services.settingsWindow.isVisible)
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        count += 1
        if !ok { failures += 1 }
        print(ok ? "PASS \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    /// Quits through NSApp.terminate, never exit(), and closes sheets first:
    /// an open sheet refuses terminate, and the run would wait forever.
    static func finish(code: Int32) {
        exitCode = code
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        NSApp.terminate(nil)
    }
}
