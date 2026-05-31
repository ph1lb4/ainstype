import Foundation
import TOMLKit

/// Custom dictionary for Whisper guidance and post-transcription replacements.
/// Reads from ~/.config/ainstype/dictionary.toml (shared with Python CLI).
class DictionaryManager {
    private let path: URL
    private var terms: [String: [String]] = ["words": [], "names": []]
    private var replacements: [String: String] = [
        "new line": "\n",
        "new paragraph": "\n\n",
        "open paren": "(",
        "close paren": ")",
        "open bracket": "[",
        "close bracket": "]",
    ]

    init(path: URL? = nil) {
        self.path = path ?? Config.configDir.appendingPathComponent("dictionary.toml")
        load()
    }

    var words: [String] { terms["words"] ?? [] }
    var names: [String] { terms["names"] ?? [] }
    var allReplacements: [String: String] { replacements }

    func setWords(_ words: [String]) { terms["words"] = words }
    func setNames(_ names: [String]) { terms["names"] = names }
    func setReplacements(_ newReplacements: [String: String]) { replacements = newReplacements }

    func reload() { load() }

    func save() {
        let table = TOMLTable()

        let termsTable = TOMLTable()
        let wordsArray = TOMLArray(terms["words"] ?? [])
        let namesArray = TOMLArray(terms["names"] ?? [])
        termsTable["words"] = wordsArray
        termsTable["names"] = namesArray
        table["terms"] = termsTable

        let repTable = TOMLTable()
        for (key, value) in replacements {
            repTable[key] = TOMLValue(stringLiteral: value)
        }
        table["replacements"] = repTable

        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? table.convert().write(to: path, atomically: true, encoding: .utf8)
    }

    private func load() {
        guard let content = try? String(contentsOf: path, encoding: .utf8),
              let table = try? TOMLTable(string: content)
        else { return }

        if let termsTable = table["terms"]?.table {
            if let words = termsTable["words"]?.array {
                terms["words"] = (0..<words.count).compactMap { words[$0]?.string }
            }
            if let names = termsTable["names"]?.array {
                terms["names"] = (0..<names.count).compactMap { names[$0]?.string }
            }
        }

        if let repTable = table["replacements"]?.table {
            replacements = [:]
            for (key, value) in repTable {
                if let str = value.string {
                    replacements[key] = str
                }
            }
        }
    }

    /// Build initial_prompt string from all terms for Whisper biasing.
    func whisperPrompt() -> String {
        let allTerms = (terms["words"] ?? []) + (terms["names"] ?? [])
        return allTerms.joined(separator: ", ")
    }

    /// Apply post-transcription spoken→written replacements (case-insensitive).
    func applyReplacements(_ text: String) -> String {
        var result = text
        for (spoken, written) in replacements {
            result = result.replacingOccurrences(
                of: spoken,
                with: written,
                options: .caseInsensitive
            )
        }
        return result
    }
}
