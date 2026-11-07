import Foundation

/// What people can change, saved as settings.json next to history.md.
public struct DictationSettings: Codable, Equatable, Sendable {
    public static let models = ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1", LocalWhisper.model]
    /// ISO 639-1 codes offered in Settings. "" lets the model detect the language.
    public static let languages = ["", "en", "es", "ca", "fr", "de", "it", "pt"]

    public var model = "gpt-4o-transcribe"
    public var language = ""
    /// Tink when the mic is live, Pop when recording stops.
    public var sounds = true
    /// Starts and stops dictation from any app.
    public var shortcut = Shortcut.standard

    public init(model: String = "gpt-4o-transcribe", language: String = "", sounds: Bool = true,
                shortcut: Shortcut = .standard) {
        self.model = model
        self.language = language
        self.sounds = sounds
        self.shortcut = shortcut
    }

    /// The name in the Settings picker.
    public static func modelName(_ model: String) -> String {
        model == LocalWhisper.model ? "Whisper large-v3-turbo (on this Mac)" : "OpenAI \(model)"
    }

    /// nil when the model should detect the language.
    public var languageCode: String? { language.isEmpty ? nil : language }

    /// Missing keys keep their defaults, so an older file still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? model
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? language
        sounds = try container.decodeIfPresent(Bool.self, forKey: .sounds) ?? sounds
        // A bad shortcut (edited by hand) falls back to ⌃. instead of losing the other settings.
        if let saved = try? container.decodeIfPresent(Shortcut.self, forKey: .shortcut), saved.problem == nil {
            shortcut = saved
        }
    }

    public static func decode(_ data: Data?) -> DictationSettings {
        data.flatMap { try? JSONDecoder().decode(DictationSettings.self, from: $0) } ?? DictationSettings()
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
