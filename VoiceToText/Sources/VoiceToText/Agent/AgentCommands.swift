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
            return ["text": text, "saved": !text.isEmpty]
        },
        AgentCommand(name: "toggle", summary: "Start when idle; stop, transcribe, and print the text when recording.",
                     example: "vtt toggle") { _, services in
            let dictation = services.dictation
            switch dictation.state {
            case .idle:
                try await dictation.start()
                return ["state": dictation.state.name]
            case .recording:
                let text = try await dictation.stop(paste: false)
                return ["state": dictation.state.name, "text": text]
            case .starting, .transcribing:
                throw DictationError.busy(dictation.state.name)
            }
        },
        AgentCommand(name: "cancel", summary: "Stop recording and throw the audio away.",
                     example: "vtt cancel") { _, services in
            let was = services.dictation.state
            await services.dictation.cancel()
            return ["canceled": was == .starting || was.name == "recording"]
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
        AgentCommand(name: "settings update", summary: "Change the model, the language, or the sounds. Only the options you give change.",
                     params: [.init(name: "model", help: DictationSettings.models.joined(separator: ", ")),
                              .init(name: "language", help: "a two-letter ISO 639-1 code like en or es, or auto to detect it"),
                              .init(name: "sounds", kind: .boolean, help: "Tink when the mic is live, Pop when it stops")],
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
            services.dictation.settings = settings
            return ["model": settings.model, "language": settings.languageCode ?? "auto", "sounds": settings.sounds]
        },
    ]
}

extension Services {
    var agentStatus: JSONObject {
        let dictation = self.dictation
        var status: JSONObject = [
            "state": dictation.state.name,
            "model": dictation.settings.model,
            "language": dictation.settings.languageCode ?? "auto",
            "sounds": dictation.settings.sounds,
            "microphone": permissions.microphone.rawValue,
            "accessibility": permissions.accessibility,
            "shortcut": hotkeys.combo.symbols,
            "shortcutRegistered": hotkeys.isRegistered,
            "history": dictation.history.count,
            "historyFile": store.historyURL.path,
            "canRetry": dictation.canRetry,
        ]
        if case .recording = dictation.state { status["recordingSeconds"] = (dictation.elapsed * 10).rounded() / 10 }
        if let error = dictation.lastError { status["lastError"] = error }
        if FileManager.default.fileExists(atPath: store.recordingURL.path) { status["lastRecording"] = store.recordingURL.path }
        return status
    }
}
