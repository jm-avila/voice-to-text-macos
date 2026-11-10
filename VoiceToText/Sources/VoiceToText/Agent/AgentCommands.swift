import Foundation
import VoiceToTextKit

/// What agents (and you, from a terminal) can do with VoiceToText. The CLI,
/// `vtt help`, and the MCP server all read this list.
enum AgentCommands {
    static let all: [AgentCommand] = [
        AgentCommand(name: "status", summary: "What the app is doing, its settings, and whether it has the key, the mic, and Accessibility.",
                     example: "vtt status --json", readOnly: true) { _, services in
            services.dictation.reloadHistory()
            var status = services.agentStatus
            // /usr/bin/security can wait on a locked keychain: never on the main thread.
            status["openAIKey"] = await Task.detached { APIKey.read() }.value == nil ? "missing" : "found"
            return status
        },
        AgentCommand(name: "start", summary: "Start recording the microphone. Returns once the mic is live: talk after that.",
                     example: "vtt start") { _, services in
            try await services.dictation.start()
            return ["state": services.dictation.state.name]
        },
        AgentCommand(name: "stop", summary: "Stop recording, transcribe, save to history, and print the text. --paste also pastes it into the front app.",
                     params: [.init(name: "paste", kind: .boolean, help: "also paste the text into the app in front")],
                     example: "vtt stop --json") { args, services in
            let text = try await services.dictation.stop(paste: try args.bool("paste") ?? false)
            var reply: JSONObject = ["text": text, "saved": !text.isEmpty, "streamed": services.dictation.lastStreamed,
                                     "inMemory": services.dictation.lastInMemory]
            // Key-up to text, in milliseconds: how fast it felt.
            if !text.isEmpty, let latency = services.dictation.lastLatency {
                reply["latencyMs"] = Int((Double(latency.components.attoseconds) / 1e15 + Double(latency.components.seconds) * 1000).rounded())
            }
            return reply
        },
        AgentCommand(name: "toggle", summary: "Start when idle; stop, transcribe, and print the text when recording.",
                     example: "vtt toggle") { _, services in
            let dictation = services.dictation
            guard dictation.allows(.stop) else {
                // Busy while the mic opens or it transcribes: start says so.
                try await dictation.start()
                return ["state": dictation.state.name]
            }
            let text = try await dictation.stop(paste: false)
            return ["state": dictation.state.name, "text": text]
        },
        AgentCommand(name: "cancel", summary: "Stop recording and throw the audio away. While transcribing, stop waiting (Retry sends it again).",
                     example: "vtt cancel") { _, services in
            ["canceled": await services.dictation.cancel()]
        },
        AgentCommand(name: "retry", summary: "Send the last failed (or canceled) recording or dropped file again, and print the text. --paste also pastes a recording.",
                     params: [.init(name: "paste", kind: .boolean, help: "also paste the text into the app in front")],
                     example: "vtt retry --json") { args, services in
            let text = try await services.dictation.retry(paste: try args.bool("paste") ?? false)
            return ["text": text, "saved": !text.isEmpty]
        },
        AgentCommand(name: "transcribe", summary: "Transcribe an audio file (m4a, mp3, wav, …) with the current model and language. Not saved to history.",
                     params: [.init(name: "file", required: true, positional: true, isPath: true, help: "the audio file")],
                     example: "vtt transcribe ~/Desktop/memo.m4a --json") { args, services in
            let path = try args.required("file")
            guard FileManager.default.fileExists(atPath: path) else { throw AgentError.notFound("no audio file: \(path)") }
            return ["text": try await services.dictation.transcribe(file: URL(fileURLWithPath: path))]
        },
        AgentCommand(name: "history list", summary: "Saved transcripts, newest first.",
                     params: [.init(name: "limit", kind: .integer, help: "how many (default 10)")],
                     example: "vtt history list --limit 3 --json", readOnly: true) { args, services in
            let limit = try args.int("limit", default: 10)
            guard limit > 0 else { throw AgentError.usage("--limit must be 1 or more") }
            services.dictation.reloadHistory()
            let history = services.dictation.history
            return ["entries": history.suffix(limit).reversed().map { ["date": $0.date, "text": $0.text] },
                    "total": history.count, "file": services.store.historyURL.path]
        },
        AgentCommand(name: "settings update", summary: "Change the model, the language, the sounds, or the menu bar icon. Only the options you give change.",
                     params: [.init(name: "model", help: DictationSettings.models.joined(separator: ", ")),
                              .init(name: "language", help: "a two-letter ISO 639-1 code like en or es, or auto to detect it"),
                              .init(name: "sounds", kind: .boolean, help: "Tink when the mic is live, Pop when it stops"),
                              .init(name: "click-to-dictate", kind: .boolean, help: "a click on the menu bar icon starts and stops dictation"),
                              .init(name: "hide-when-idle", kind: .boolean, help: "show the menu bar icon only while dictating")],
                     example: "vtt settings update --language es --json") { args, services in
            // Check every option before changing anything.
            var settings = services.dictation.settings
            if let model = args.string("model") {
                guard DictationSettings.models.contains(model) else {
                    throw AgentError.usage("unknown model \"\(model)\". Use one of: \(DictationSettings.models.joined(separator: ", "))")
                }
                settings.model = model
            }
            if let language = args.string("language")?.lowercased() {
                guard language == "auto" || language.wholeMatch(of: /[a-z]{2}/) != nil else {
                    throw AgentError.usage("--language takes a two-letter code like en or es, or auto")
                }
                settings.language = language == "auto" ? "" : language
            }
            if let sounds = try args.bool("sounds") { settings.sounds = sounds }
            if let click = try args.bool("click-to-dictate") { settings.clickToDictate = click }
            if let hide = try args.bool("hide-when-idle") { settings.hideWhenIdle = hide }
            services.dictation.settings = settings
            return ["model": settings.model, "language": settings.languageCode ?? "auto", "sounds": settings.sounds,
                    "clickToDictate": settings.clickToDictate, "hideWhenIdle": settings.hideWhenIdle]
        },
    ]
}

extension Services {
    var agentStatus: JSONObject {
        let dictation = self.dictation
        var status: JSONObject = [
            "state": dictation.state.name,
            // With the unseen one: "priming" while a held ⌥⌘ opens the mic before it fires.
            "phase": dictation.phaseName,
            // The commands that work right now. Anything else answers busy, not recording, or nothing to retry.
            "actions": Self.actions(dictation),
            "model": dictation.settings.model,
            "language": dictation.settings.languageCode ?? "auto",
            "sounds": dictation.settings.sounds,
            "clickToDictate": dictation.settings.clickToDictate,
            "hideWhenIdle": dictation.settings.hideWhenIdle,
            "microphone": permissions.microphone.rawValue,
            "accessibility": permissions.accessibility,
            "shortcut": hotkeys.combo.symbols,
            "shortcutRegistered": hotkeys.isRegistered,
            "history": dictation.history.count,
            "historyFile": store.historyURL.path,
            "canRetry": dictation.canRetry,
            "localModel": LocalWhisper.status.rawValue,
            // Loaded and waiting: no model load at key-up, and dictations stream.
            "localModelLoaded": server?.isReady ?? false,
            "parakeetModel": Parakeet.status.rawValue,
            "parakeetLoaded": parakeet?.isLoaded ?? false,
            "models": [
                LocalWhisper.model: Self.model(installed: LocalWhisper.status.rawValue, permissions.whisper),
                Parakeet.model: Self.model(installed: Parakeet.status.rawValue, permissions.parakeet),
            ],
        ]
        switch dictation.retryable {
        case .recording?: status["retry"] = "recording"
        case .file(let file)?: status["retry"] = file.path
        case nil: break
        }
        if let outcome = dictation.lastOutcome { status["lastOutcome"] = outcome.name }
        if case .recording = dictation.state { status["recordingSeconds"] = (dictation.elapsed * 10).rounded() / 10 }
        if let error = dictation.lastError { status["lastError"] = error }
        if let waiting = permissions.waiting(for: dictation.settings.model), dictation.state == .transcribing {
            status["waiting"] = waiting
        }
        if FileManager.default.fileExists(atPath: store.recordingURL.path) { status["lastRecording"] = store.recordingURL.path }
        return status
    }

    /// toggle is in the list whenever start or stop is.
    static func actions(_ dictation: Dictation) -> [String] {
        let allowed = dictation.allowedActions
        var names = allowed.map(\.rawValue)
        if allowed.contains(.start) || allowed.contains(.stop) {
            names.insert("toggle", at: names.firstIndex(of: "cancel") ?? names.firstIndex(of: "retry") ?? names.endIndex)
        }
        return names
    }

    /// Downloaded (installed), and whether it is in memory now; why it failed to load.
    static func model(installed: String, _ residency: ModelResidency) -> JSONObject {
        var model: JSONObject = ["installed": installed, "residency": residency.name]
        if let error = residency.error { model["error"] = error }
        return model
    }
}
