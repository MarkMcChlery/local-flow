import Foundation

/// Saves every dictation as a Markdown memo, filed into a topic folder
/// guessed from its content (via `Cleaner.classifyTopic`, on-device).
///
/// Deliberately best-effort: this runs after the transcript has already
/// been typed at the cursor, and any failure here (no disk space, folder
/// permissions, model unavailable) is swallowed. Archiving must never be
/// able to break live dictation.
enum MemoArchiver {

    static func archive(text: String, topics: [String]) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let topic = await Cleaner.classifyTopic(trimmed, topics: topics) ?? "Uncategorized"
        let folder = baseFolder.appendingPathComponent(topic, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(filename())
            try memoContents(text: trimmed, topic: topic).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Silent by design — see type doc comment.
        }
    }

    /// Resolves the configured memo folder (default: ~/Documents/Voice Memos;
    /// change it in Settings -> Memos).
    static var baseFolder: URL {
        let raw = UserDefaults.standard.string(forKey: SettingKey.memoFolder) ?? SettingKey.defaultMemoFolder
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private static func filename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter.string(from: Date()) + ".md"
    }

    private static func memoContents(text: String, topic: String) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return """
        # Voice memo

        **Date:** \(formatter.string(from: Date()))
        **Topic:** \(topic)

        \(text)
        """
    }
}
