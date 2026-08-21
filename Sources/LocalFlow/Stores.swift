import Foundation

// Simple JSON persistence in ~/Library/Application Support/LocalFlow/.
// Deliberately no database: two small lists, human-readable on disk.

enum Storage {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LocalFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load<T: Codable>(_ filename: String, fallback: T) -> T {
        let url = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            return fallback
        }
        return decoded
    }

    static func save<T: Codable>(_ value: T, to filename: String) {
        let url = directory.appendingPathComponent(filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Personal dictionary ("wrong" -> "right" word pairs)

struct WordPair: Codable, Identifiable, Hashable {
    var id = UUID()
    var wrong: String
    var right: String
}

@MainActor
final class DictionaryStore: ObservableObject {
    @Published var pairs: [WordPair] {
        didSet { Storage.save(pairs, to: "dictionary.json") }
    }

    init() {
        pairs = Storage.load("dictionary.json", fallback: [WordPair]())
    }

    func add() {
        pairs.append(WordPair(wrong: "", right: ""))
    }

    func remove(_ pair: WordPair) {
        pairs.removeAll { $0.id == pair.id }
    }

    /// Case-insensitive whole-word replacement of each "wrong" with its "right".
    /// Static and nonisolated so it is unit-testable without touching
    /// persistence or the main actor.
    nonisolated static func applyPairs(_ pairs: [WordPair], to text: String) -> String {
        var result = text
        for pair in pairs {
            let wrong = pair.wrong.trimmingCharacters(in: .whitespaces)
            let right = pair.right.trimmingCharacters(in: .whitespaces)
            guard !wrong.isEmpty, !right.isEmpty else { continue }
            let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: wrong) + "\\b"
            result = result.replacingOccurrences(
                of: pattern,
                with: NSRegularExpression.escapedTemplate(for: right),
                options: .regularExpression
            )
        }
        return result
    }

    func apply(to text: String) -> String {
        Self.applyPairs(pairs, to: text)
    }
}

// MARK: - Voice snippets (spoken trigger -> expansion text)

struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var trigger: String
    var expansion: String
}

@MainActor
final class SnippetStore: ObservableObject {
    @Published var snippets: [Snippet] {
        didSet { Storage.save(snippets, to: "snippets.json") }
    }

    init() {
        snippets = Storage.load("snippets.json", fallback: [Snippet]())
    }

    func add() {
        snippets.append(Snippet(trigger: "", expansion: ""))
    }

    func remove(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
    }

    /// If the whole transcript matches a trigger phrase
    /// (ignoring case and punctuation), return its expansion.
    func expansion(for transcript: String) -> String? {
        Self.expansion(for: transcript, in: snippets)
    }

    /// Static and nonisolated matching core, unit-testable without
    /// touching persistence or the main actor.
    nonisolated static func expansion(for transcript: String, in snippets: [Snippet]) -> String? {
        let normalisedTranscript = normalise(transcript)
        guard !normalisedTranscript.isEmpty else { return nil }
        for snippet in snippets {
            let trigger = normalise(snippet.trigger)
            if !trigger.isEmpty, trigger == normalisedTranscript {
                return snippet.expansion
            }
        }
        return nil
    }

    private nonisolated static func normalise(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
