import Foundation
import TOMLKit

/// Custom dictionary for Whisper guidance and post-transcription replacements.
/// Reads from ~/.config/ainstype/dictionary.toml (shared with Python CLI).
///
/// Thread safety: replacements are applied every second from live-mode tasks
/// while the settings window mutates the dictionary on the main thread, so all
/// state is guarded by a lock. Derived data (compiled regexes, holdback
/// prefixes) is rebuilt on mutation, not on every apply.
class DictionaryManager {
    private let path: URL
    private let lock = NSLock()

    /// Custom terms ([terms] words/names in the TOML). No longer editable or
    /// used for Whisper prompt biasing — WhisperKit (verified 0.17.0 through
    /// 1.0.0) returns empty transcriptions when `promptTokens` is set — but the
    /// section is preserved on save because the file is shared with the Python
    /// CLI, which still reads it.
    private var terms: [String: [String]] = ["words": [], "names": []]
    private var replacements: [String: String] = [:]

    /// Replacement rules ordered longest-spoken-phrase first, with the word-
    /// boundary regex precompiled (nil = plain string replacement).
    private var compiledRules: [(spoken: String, written: String, regex: NSRegularExpression?)] = []
    /// Lowercased word-sequences that are proper prefixes of a multi-word rule,
    /// used by live mode to hold back words that may start a spoken phrase.
    private var holdbackPrefixes: Set<[String]> = []
    private var maxHoldbackWords = 0

    private static let defaultReplacements: [String: String] = [
        "new line": "\n",
        "new paragraph": "\n\n",
        "open paren": "(",
        "close paren": ")",
        "open bracket": "[",
        "close bracket": "]",
    ]

    init(path: URL? = nil) {
        self.path = path ?? Config.configDir.appendingPathComponent("dictionary.toml")
        lock.withLock {
            replacements = Self.defaultReplacements
            rebuildDerivedLocked()
        }
        load()
    }

    var allReplacements: [String: String] { lock.withLock { replacements } }

    func setReplacements(_ newReplacements: [String: String]) {
        lock.withLock {
            replacements = newReplacements
            rebuildDerivedLocked()
        }
    }

    func reload() { load() }

    func save() {
        let (savedTerms, savedReplacements) = lock.withLock { (terms, replacements) }

        let table = TOMLTable()

        let termsTable = TOMLTable()
        termsTable["words"] = TOMLArray(savedTerms["words"] ?? [])
        termsTable["names"] = TOMLArray(savedTerms["names"] ?? [])
        table["terms"] = termsTable

        let repTable = TOMLTable()
        for (key, value) in savedReplacements {
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

        lock.withLock {
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
                rebuildDerivedLocked()
            }
        }
    }

    /// Rebuild rule ordering, compiled regexes and holdback prefixes.
    /// Must be called with `lock` held.
    private func rebuildDerivedLocked() {
        compiledRules = replacements
            .filter { !$0.key.isEmpty }
            .sorted { $0.key.count > $1.key.count }
            .map { (spoken, written) in
                (spoken, written, Self.wordBoundaryRegex(for: spoken))
            }

        holdbackPrefixes = []
        maxHoldbackWords = 0
        for key in replacements.keys {
            let keyWords = key.lowercased().split(separator: " ").map(String.init)
            guard keyWords.count >= 2 else { continue }
            for length in 1..<keyWords.count {
                holdbackPrefixes.insert(Array(keyWords.prefix(length)))
                maxHoldbackWords = max(maxHoldbackWords, length)
            }
        }
    }

    /// Split `text` so that a trailing word-sequence that could be the beginning
    /// of a multi-word replacement phrase is held back (returned as `hold`)
    /// instead of emitted. Live mode types confirmed chunks immediately and can
    /// never retract them, so a phrase like "new line" split across two chunks
    /// ("… new" | "line …") would otherwise miss its replacement forever. The
    /// held text is prepended to the next chunk, where the completed phrase can
    /// match. `hold` keeps its leading space so spacing survives re-emission.
    func holdbackSplit(_ text: String) -> (emit: String, hold: String) {
        let (prefixes, maxWords) = lock.withLock { (holdbackPrefixes, maxHoldbackWords) }
        guard maxWords > 0 else { return (text, "") }

        let words = text.split(separator: " ")
        guard !words.isEmpty else { return (text, "") }

        // Longest candidate first, so "full stop" is held over just "stop".
        for count in stride(from: min(maxWords, words.count), through: 1, by: -1) {
            let tail = words.suffix(count).map { $0.lowercased() }
            guard prefixes.contains(tail) else { continue }

            // Split before the first held word, pulling its preceding spaces
            // into `hold` so re-emission preserves separation.
            var splitIndex = words[words.count - count].startIndex
            while splitIndex > text.startIndex, text[text.index(before: splitIndex)] == " " {
                splitIndex = text.index(before: splitIndex)
            }
            return (String(text[..<splitIndex]), String(text[splitIndex...]))
        }
        return (text, "")
    }

    /// Apply post-transcription spoken→written replacements (case-insensitive).
    ///
    /// Rules are applied longest-spoken-phrase first so they're deterministic
    /// (Swift `Dictionary` iteration order is not) and so a longer phrase isn't
    /// partially consumed by a shorter overlapping rule. Word-like terms match on
    /// word boundaries so e.g. "open paren" doesn't fire inside another word.
    func applyReplacements(_ text: String) -> String {
        let rules = lock.withLock { compiledRules }
        var result = text
        for (spoken, written, regex) in rules {
            if let regex {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(for: written)
                )
            } else {
                result = result.replacingOccurrences(of: spoken, with: written, options: .caseInsensitive)
            }
        }
        return result
    }

    /// Word-boundary regex for word-like terms; nil for terms where a plain
    /// case-insensitive replace is the right behavior (e.g. ":)").
    private static func wordBoundaryRegex(for spoken: String) -> NSRegularExpression? {
        let wordLike = (spoken.first?.isLetter ?? false || spoken.first?.isNumber ?? false)
            && (spoken.last?.isLetter ?? false || spoken.last?.isNumber ?? false)
        guard wordLike else { return nil }
        return try? NSRegularExpression(
            pattern: "\\b" + NSRegularExpression.escapedPattern(for: spoken) + "\\b",
            options: [.caseInsensitive]
        )
    }
}
