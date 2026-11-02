import Foundation

/// One saved transcript.
public struct HistoryEntry: Equatable, Sendable {
    /// Local time as written in the file: "2026-09-27 13:14:48".
    public var date: String
    public var text: String

    public init(date: String, text: String) {
        self.date = date
        self.text = text
    }
}

/// history.md, in the bash tool's format, so both tools share one file:
///
///     ## 2026-09-27 13:14:48
///
///     Hello, this is a test.
///
/// Append-only. Empty transcripts are never saved.
public enum HistoryLog {
    public static func entry(_ text: String, at date: Date, timeZone: TimeZone = .current) -> String {
        "## \(stamp(date, timeZone: timeZone))\n\n\(text)\n\n"
    }

    public static func stamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Every entry, oldest first. Lines before the first header are ignored.
    public static func parse(_ markdown: String) -> [HistoryEntry] {
        var entries: [HistoryEntry] = []
        var lines: [String] = []
        func close() {
            guard !entries.isEmpty else { return }
            entries[entries.count - 1].text = lines.joined(separator: "\n")
            lines = []
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                close()
                entries.append(HistoryEntry(date: String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), text: ""))
            } else if !entries.isEmpty, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(String(line))
            }
        }
        close()
        return entries
    }
}
