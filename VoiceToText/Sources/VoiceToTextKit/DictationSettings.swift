import Foundation

/// What people can change, saved as settings.json next to history.md.
public struct DictationSettings: Codable, Equatable, Sendable {
    public static let models = ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1", LocalWhisper.model, Parakeet.model]
    /// ISO 639-1 codes offered in Settings. "" lets the model detect the language.
    public static let languages = ["", "en", "es", "ca", "fr", "de", "it", "pt"]

    public var model = Parakeet.model
    public var language = ""
    /// Tink when the mic is live, Pop when recording stops.
    public var sounds = true
    /// Starts and stops dictation from any app.
    public var shortcut = Shortcut.standard
    /// A click on the menu bar icon starts and stops dictation; right-click or ⌥-click opens the menu.
    public var clickToDictate = false
    /// The menu bar icon shows only while dictating (or after a failure).
    public var hideWhenIdle = false

    public init(model: String = Parakeet.model, language: String = "", sounds: Bool = true,
                shortcut: Shortcut = .standard, clickToDictate: Bool = false, hideWhenIdle: Bool = false) {
        self.model = model
        self.language = language
        self.sounds = sounds
        self.shortcut = shortcut
        self.clickToDictate = clickToDictate
        self.hideWhenIdle = hideWhenIdle
    }

    /// The name in the Settings picker.
    public static func modelName(_ model: String) -> String {
        switch model {
        case LocalWhisper.model: "Whisper large-v3-turbo (on this Mac)"
        case Parakeet.model: "Parakeet Ultra (on this Mac, fastest)"
        default: "OpenAI \(model)"
        }
    }

    /// nil when the model should detect the language.
    public var languageCode: String? { language.isEmpty ? nil : language }

    /// Missing keys keep their defaults, so an older file still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? model
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? language
        sounds = try container.decodeIfPresent(Bool.self, forKey: .sounds) ?? sounds
        clickToDictate = try container.decodeIfPresent(Bool.self, forKey: .clickToDictate) ?? clickToDictate
        hideWhenIdle = try container.decodeIfPresent(Bool.self, forKey: .hideWhenIdle) ?? hideWhenIdle
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
