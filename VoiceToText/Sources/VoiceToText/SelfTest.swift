import AppKit
import Carbon.HIToolbox
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
        // The test copy's own grants don't matter: S-013 turns them off on purpose.
        let permissions = services.permissions
        permissions.accessibility = true
        permissions.microphone = .granted

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
        check("S-012 the menu bar shows the level and the time, not a mic",
              services.statusItem.symbolName == "level" && services.statusItem.title.hasPrefix("0:0"))
        let hud = services.hud.window
        check("the HUD never takes focus or clicks", hud?.canBecomeKey == false && hud?.canBecomeMain == false
                && hud?.styleMask.contains(.nonactivatingPanel) == true && hud?.ignoresMouseEvents == true)

        transcriber.delay = .milliseconds(300)
        let stopping = Task { await dictation.toggle() }
        await wait(0.1)
        check("S-002 the second press transcribes", dictation.state == .transcribing)
        check("S-002 Pop plays on the second press", dictation.sounds.lastCue == .stop)
        check("S-012 the menu bar shows dots while transcribing", services.statusItem.symbolName == "dots"
                && services.statusItem.title.isEmpty)
        await dictation.toggle()
        check("S-003 a press while transcribing is ignored", dictation.state == .transcribing)
        await stopping.value
        check("S-001 the text is pasted", paster.last?.text == "Hello from the self-test." && paster.last?.pasted == true)
        check("S-004 the text stays on the clipboard", paster.pasteboard.string(forType: .string) == "Hello from the self-test.")
        check("S-001 the HUD says Pasted", dictation.notice == .pasted && services.hud.isVisible)
        check("S-012 the menu bar flashes a checkmark after the paste", services.statusItem.symbolName == "checkmark")
        check("S-001 back to ready", dictation.state == .idle)
        check("the transcriber got the recording, the model, and no language",
              transcriber.calls.last?.file == store.recordingURL && transcriber.calls.last?.model == "gpt-4o-transcribe"
                && transcriber.calls.last?.language == nil)
        await wait(1.5)
        check("the HUD hides after the notice", !services.hud.isVisible)
        check("S-012 then the waveform, with no failure dot", services.statusItem.symbolName == "waveform" && !services.statusItem.hasFailureDot)

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

        // A new start replaces the kept recording: no retry offered after it.
        transcriber.reply = .failure(TranscriptionError.network("offline"))
        try? await dictation.start()
        _ = try? await dictation.stop(paste: true)
        recorder.failure = RecorderError.silent(.seconds(10))
        _ = try? await dictation.start()
        check("S-006 after a new start fails, the old recording is not offered for retry", !dictation.canRetry)
        transcriber.reply = .success("Second try worked.")

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

        // S-003 A press and an instant change of mind sends nothing.
        let sent = transcriber.calls.count
        recorder.duration = 0.1
        try? await dictation.start()
        let blink = try? await dictation.stop(paste: true)
        check("S-003 a recording under 0.3 s is not sent", blink == "" && transcriber.calls.count == sent
                && dictation.notice == .nothingHeard && dictation.state == .idle)
        recorder.duration = 1.5

        // S-005 The bash tool appends too: the menu and the CLI read the file again.
        try? store.appendHistory("Written by the bash tool.")
        services.statusItem.menuNeedsUpdate(NSMenu())
        check("S-005 an entry the bash tool appends shows in the menu", dictation.history.last?.text == "Written by the bash tool.")
        // A history.md that cannot be written is left as it is, never replaced.
        let fileBefore = historyFile()
        chmod(store.historyURL.path, 0o444)
        transcriber.reply = .success("Not saved.")
        try? await dictation.start()
        let unsaved = try? await dictation.stop(paste: false)
        chmod(store.historyURL.path, 0o644)
        check("S-005 when history.md is read-only, it keeps every entry and the error shows",
              unsaved == "Not saved." && historyFile() == fileBefore && dictation.lastError?.contains("history") == true)

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

        // S-011 Change the shortcut: the next press with ⌃ or ⌥ becomes it, saved to settings.json.
        func press(_ keyCode: Int, _ flags: NSEvent.ModifierFlags, _ characters: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                             keyCode: UInt16(keyCode))!
        }
        let shortcuts = services.shortcutRecorder
        let optionD = Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: Shortcut.option | Shortcut.command, key: "D")
        check("S-011 a key press reads as the key printed on it", Shortcut(event: press(kVK_ANSI_D, [.option, .command], "∂")) == optionD,
              Shortcut(event: press(kVK_ANSI_D, [.option, .command], "∂")).symbols)
        check("S-011 ⌘ alone is refused (⌘W would close windows in every app)",
              Shortcut(event: press(kVK_ANSI_W, .command, "w")).problem != nil)
        check("S-011 ß stays one letter, other letters are capitals",
              Shortcut.name(keyCode: kVK_ANSI_Minus, plain: "ß") == "ß" && Shortcut.name(keyCode: kVK_ANSI_D, plain: "d") == "D")
        check("S-011 a private-use glyph (Help, keypad Clear) is no name",
              Shortcut.name(keyCode: kVK_Help, plain: "\u{F746}").isEmpty && Shortcut.name(keyCode: kVK_F13, plain: "\u{F710}") == "F13")
        check("S-011 Space has a name and no menu key",
              Shortcut(event: press(kVK_Space, .control, " ")).symbols == "⌃Space" && Shortcut(event: press(kVK_Space, .control, " ")).menuKey == "")
        check("S-011 a press is ignored until Change is clicked", !shortcuts.handle(press(kVK_ANSI_D, [.option, .command], "d")))
        shortcuts.start()
        check("S-011 Change starts recording", shortcuts.isRecording)
        check("S-011 a key with only ⇧ is refused and recording goes on",
              shortcuts.handle(press(kVK_ANSI_D, .shift, "D")) && shortcuts.problem != nil && shortcuts.isRecording
                && dictation.settings.shortcut == .standard)
        _ = shortcuts.handle(press(kVK_Escape, [], "\u{1b}"))
        check("S-011 Escape cancels and keeps the shortcut", !shortcuts.isRecording && dictation.settings.shortcut == .standard)
        shortcuts.start()
        _ = shortcuts.handle(press(kVK_ANSI_D, [.option, .command], "d"))
        check("S-011 the new shortcut is used and saved",
              !shortcuts.isRecording && shortcuts.problem == nil && services.hotkeys.combo == optionD
                && Store(directory: store.directory).loadSettings().shortcut == optionD)
        check("S-011 status reports the new shortcut", result(await agent("status"))?["shortcut"] as? String == "⌥⌘D")
        func flags(_ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_Option))!
        }
        shortcuts.start()
        _ = shortcuts.handle(flags(.option))
        _ = shortcuts.handle(flags([]))
        check("S-011 one modifier let go is not a shortcut yet", shortcuts.isRecording && shortcuts.problem == nil)
        _ = shortcuts.handle(flags([.shift, .command]))
        _ = shortcuts.handle(flags([]))
        check("S-011 ⇧⌘ alone is refused and recording goes on", shortcuts.isRecording && shortcuts.problem != nil)
        _ = shortcuts.handle(flags(.option))
        _ = shortcuts.handle(flags([.option, .command]))
        _ = shortcuts.handle(press(kVK_ANSI_D, [.option, .command], "d"))
        check("S-011 a key with the modifiers beats modifiers alone", services.hotkeys.combo == optionD && !shortcuts.isRecording)
        let optionCommand = Shortcut.modifiersOnly(Shortcut.option | Shortcut.command)
        shortcuts.start()
        for held: NSEvent.ModifierFlags in [.option, [.option, .command], .command, []] { _ = shortcuts.handle(flags(held)) }
        check("S-011 ⌥⌘ pressed and let go becomes the shortcut, saved",
              !shortcuts.isRecording && services.hotkeys.combo == optionCommand
                && Store(directory: store.directory).loadSettings().shortcut == optionCommand)
        check("S-011 status reports ⌥⌘", result(await agent("status"))?["shortcut"] as? String == "⌥⌘")
        shortcuts.reset()
        check("S-011 Reset goes back to ⌃.", services.hotkeys.combo == .standard
                && Store(directory: store.directory).loadSettings().shortcut == .standard)
        shortcuts.start()
        services.settingsWindow.show()
        services.settingsWindow.close()
        await wait(0.2)
        check("S-011 closing Settings stops recording", !shortcuts.isRecording)

        // S-012 The menu bar icon.
        let icon: StatusItem = services.statusItem
        transcriber.reply = .failure(TranscriptionError.api(status: 500, message: "Server down"))
        try? await dictation.start()
        _ = try? await dictation.stop(paste: true)
        check("S-012 a failure flashes ✕, then leaves a dot", icon.symbolName == "xmark" && icon.hasFailureDot)
        icon.menuWillOpen(NSMenu())
        icon.menuDidClose(NSMenu())
        check("S-012 opening the menu clears the dot", !icon.hasFailureDot)
        transcriber.reply = .success("Back.")
        try? await dictation.start()
        _ = try? await dictation.stop(paste: true)
        check("S-012 a good try after a failure has no dot", !icon.hasFailureDot && dictation.lastError == nil)
        await wait(1.5)
        check("S-012 the icon shows by default, and a click opens the menu", icon.isShown && !icon.clickDictates)
        let menuSettings = result(await agent("settings update", ["click-to-dictate": "true", "hide-when-idle": "true"]))
        check("S-012 settings update turns on click to dictate and hide when idle",
              menuSettings?["clickToDictate"] as? Bool == true && dictation.settings.hideWhenIdle
                && Store(directory: store.directory).loadSettings().clickToDictate)
        check("S-012 a click dictates, and the idle icon hides", icon.clickDictates && !icon.isShown)
        try? await dictation.start()
        check("S-012 the hidden icon shows while recording", icon.isShown)
        await dictation.cancel()
        await wait(1.5)
        check("S-012 and hides again after", !icon.isShown)
        transcriber.reply = .failure(TranscriptionError.api(status: 500, message: "Server down"))
        try? await dictation.start()
        _ = try? await dictation.stop(paste: true)
        await wait(4.5)
        check("S-012 a failure keeps the hidden icon shown, with its dot", icon.isShown && icon.hasFailureDot)
        icon.menuWillOpen(NSMenu())
        icon.menuDidClose(NSMenu())
        check("S-012 opening the menu hides it again", !icon.isShown)
        _ = await agent("settings update", ["click-to-dictate": "false", "hide-when-idle": "false"])
        check("S-012 turned off: the menu is back and the icon shows", !icon.clickDictates && icon.isShown)
        // A file dropped on the icon.
        check("S-012 a drop takes audio, MP4 and QuickTime files only",
              StatusItem.audioFile(URL(fileURLWithPath: "/tmp/a.m4a")) && StatusItem.audioFile(URL(fileURLWithPath: "/tmp/a.mp3"))
                && StatusItem.audioFile(URL(fileURLWithPath: "/tmp/a.mov")) && StatusItem.audioFile(URL(fileURLWithPath: "/tmp/a.mp4"))
                && !StatusItem.audioFile(URL(fileURLWithPath: "/tmp/a.mkv")) && !StatusItem.audioFile(URL(fileURLWithPath: "/tmp/a.txt"))
                && !StatusItem.audioFile(URL(string: "https://example.com/a.m4a")!))
        transcriber.reply = .success("From a dropped file.")
        let droppedFile = store.directory.appending(path: "dropped.m4a")
        try? Data("memo".utf8).write(to: droppedFile)
        paster.pasteboard.clearContents()
        let dropped = try? await dictation.transcribeDropped(droppedFile)
        check("S-012 a dropped file is transcribed, saved, and copied, not pasted",
              dropped == "From a dropped file." && transcriber.calls.last?.file == droppedFile
                && dictation.history.last?.text == "From a dropped file." && dictation.notice == .copied
                && paster.pasteboard.string(forType: .string) == "From a dropped file.")
        await wait(1.5)

        // S-013 Missing access is asked for up front and shown, never found out after talking.
        permissions.accessibility = false
        let menu = NSMenu()
        icon.menuNeedsUpdate(menu)
        let fixItem = menu.items.first { $0.title == Permissions.Need.accessibility.menuTitle }
        check("S-013 the menu offers to allow Accessibility, first", fixItem != nil && menu.items.firstIndex { $0 === fixItem } ?? 99 < 3)
        icon.refresh()
        check("S-013 the icon keeps a dot and says what is missing", icon.needsAccess && icon.isShown)
        services.settingsWindow.close()
        let blockedFrom = transcriber.calls.count
        await dictation.toggle()
        check("S-013 the shortcut opens Settings instead of recording", dictation.state == .idle
                && services.settingsWindow.isVisible && transcriber.calls.count == blockedFrom)
        try? await dictation.start()
        check("S-013 the CLI still records (it pastes nothing)", dictation.state.name == "recording")
        await dictation.cancel()
        permissions.accessibility = true
        permissions.microphone = .denied
        check("S-013 a denied mic opens System Settings", permissions.missing == [.microphone] && permissions.fixTitle(.microphone) == "Open Settings")
        permissions.microphone = .granted
        icon.menuNeedsUpdate(menu)
        check("S-013 all allowed: no warning, and the shortcut records", !icon.needsAccess
                && !menu.items.contains { $0.title == Permissions.Need.accessibility.menuTitle })
        await dictation.toggle()
        check("S-013 with everything allowed the shortcut records", dictation.state.name == "recording")
        await dictation.cancel()
        services.settingsWindow.close()

        // S-014 The local model: pieces are transcribed while you talk; key-up only sends the rest.
        func tone(_ seconds: Double, _ amplitude: Float) -> [Float] {
            (0..<Int(seconds * Double(WAV.rate))).map { amplitude * sin(Float($0) * 2 * .pi * 220 / Float(WAV.rate)) }
        }
        dictation.settings.model = LocalWhisper.model
        dictation.settings.language = "es"
        transcriber.resetPieces()
        transcriber.pieceReply = .success("Una pieza.")
        let filesBefore = transcriber.calls.count
        try? await dictation.start()
        check("S-014 the local model asks the mic for its audio as it arrives", recorder.streamed)
        recorder.speak(tone(5, 0.3) + tone(1, 0.0005))
        await wait(0.3)
        check("S-014 a piece is transcribed during the dictation, in the chosen language",
              transcriber.pieces.count == 1 && transcriber.pieces.first?.language == "es")
        recorder.speak(tone(1, 0.3))
        let streamed = result(await agent("stop"))
        check("S-014 at key-up only the rest is sent, with the text before it as prompt, and no whole file",
              transcriber.pieces.count == 2 && transcriber.pieces.last?.prompt == "Una pieza." && transcriber.calls.count == filesBefore
                && streamed?["text"] as? String == "Una pieza. Una pieza." && streamed?["streamed"] as? Bool == true)
        check("S-014 stop reports key-up to text in ms", (streamed?["latencyMs"] as? Int).map { $0 >= 0 && $0 < 1000 } == true)

        transcriber.pieceReply = .failure(TranscriptionError.local("whisper-server: gone"))
        transcriber.reply = .success("The whole file.")
        try? await dictation.start()
        recorder.speak(tone(5, 0.3) + tone(1, 0.0005))
        await wait(0.3)
        check("S-014 a failed piece falls back to the whole file", (try? await dictation.stop(paste: false)) == "The whole file."
                && transcriber.calls.count == filesBefore + 1)

        transcriber.isReady = false
        try? await dictation.start()
        check("S-014 with the server not loaded yet, nothing streams", !recorder.streamed)
        _ = try? await dictation.stop(paste: false)
        transcriber.isReady = true
        dictation.settings.model = "gpt-4o-transcribe"
        try? await dictation.start()
        check("S-014 OpenAI models never stream", !recorder.streamed)
        await dictation.cancel()
        transcriber.pieceReply = .success("Piece.")

        // S-016 Parakeet: the whole recording at key-up, no stream, with its model id and the language as a hint.
        let beforeParakeet = dictation.settings
        dictation.settings.model = Parakeet.model
        dictation.settings.language = "es"
        transcriber.reply = .success("Desde Parakeet.")
        try? await dictation.start()
        check("S-016 Parakeet does not stream (the whole dictation takes ~0.1 s)", !recorder.streamed)
        check("S-016 Parakeet gets the whole recording with its model and language",
              (try? await dictation.stop(paste: false)) == "Desde Parakeet."
                && transcriber.calls.last?.model == Parakeet.model && transcriber.calls.last?.language == "es")
        check("S-016 Settings and the CLI offer Parakeet by name",
              DictationSettings.models.contains(Parakeet.model)
                && DictationSettings.modelName(Parakeet.model).hasPrefix("Parakeet"))
        transcriber.reply = .success("Hello from the fake transcriber.")
        dictation.settings = beforeParakeet

        // S-015 One click between Spanish and English in the menu.
        let languages = NSMenu()
        icon.menuNeedsUpdate(languages)
        func languageItem(_ title: String) -> NSMenuItem? { languages.items.first { $0.title == title } }
        let english = languageItem(SettingsView.languageName("en"))
        check("S-015 the menu lists Español and English, the current one ticked",
              languageItem(SettingsView.languageName("es"))?.state == .on && english?.state == .off)
        english.map { _ = ($0.target as? NSObject)?.perform($0.action) }
        check("S-015 a click switches the language and saves it",
              dictation.settings.language == "en" && Store(directory: store.directory).loadSettings().language == "en")
        dictation.settings.language = "fr"
        icon.menuNeedsUpdate(languages)
        check("S-015 another language from Settings shows too, ticked", languageItem(SettingsView.languageName("fr"))?.state == .on)
        dictation.settings = DictationSettings()

        // Every SF Symbol the app uses exists.
        let symbols = ["waveform", "mic", "mic.fill", "checkmark", "xmark", "checkmark.circle.fill", "doc.on.clipboard", "ear",
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
