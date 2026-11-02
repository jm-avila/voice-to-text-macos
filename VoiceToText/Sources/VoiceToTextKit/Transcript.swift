import Foundation

/// What the transcription API sends back, made ready to paste.
public enum Transcript {
    /// One line, trimmed: line breaks become single spaces, like the bash tool.
    public static func clean(_ raw: String) -> String {
        raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Recording time as people read it: 0:07, 12:34, 1:02:03.
public enum Elapsed {
    public static func text(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

/// The microphone level for the meter, 0 (silence) to 1 (loud), from the
/// recorder's average power in decibels (-160 to 0).
public enum Meter {
    public static let floor: Float = -50

    public static func level(decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
        return min(1, max(0, (decibels - floor) / -floor))
    }
}
