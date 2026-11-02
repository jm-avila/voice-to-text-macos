import Foundation
import VoiceToTextKit

/// Where files live: ~/Library/Application Support/voice-to-text/, the bash
/// tool's folder, so both share history.md.
///   history.md           every transcript (HistoryLog format), append-only
///   settings.json        model, language, sounds
///   last-recording.m4a   the latest recording, kept so a failed one can be retried
///   agent.sock           the agent CLI's socket
/// APP_STORE=<folder> uses another folder (tests, snapshots, experiments).
struct Store {
    let directory: URL

    /// True when APP_STORE points somewhere else (tests, snapshots, seed data).
    static var isOverridden: Bool {
        !(ProcessInfo.processInfo.environment["APP_STORE"] ?? "").isEmpty
    }

    static var defaultDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["APP_STORE"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL.applicationSupportDirectory.appending(path: "voice-to-text", directoryHint: .isDirectory)
    }

    init(directory: URL = Store.defaultDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var historyURL: URL { directory.appending(path: "history.md") }
    var settingsURL: URL { directory.appending(path: "settings.json") }
    var recordingURL: URL { directory.appending(path: "last-recording.m4a") }

    func loadHistory() -> [HistoryEntry] {
        HistoryLog.parse((try? String(contentsOf: historyURL, encoding: .utf8)) ?? "")
    }

    /// Appends one entry. Never rewrites the file, so the bash tool's
    /// entries and any edits by hand stay as they are.
    /// O_APPEND, like the bash tool's `>>`: when the file cannot be opened it
    /// fails instead of writing a new file over the old one.
    func appendHistory(_ text: String, at date: Date = .now) throws {
        let data = Data(HistoryLog.entry(text, at: date).utf8)
        let fd = open(historyURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: historyURL.path]) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
    }

    func loadSettings() -> DictationSettings { DictationSettings.decode(try? Data(contentsOf: settingsURL)) }

    func save(_ settings: DictationSettings) {
        try? settings.encoded().write(to: settingsURL, options: .atomic)
    }
}
