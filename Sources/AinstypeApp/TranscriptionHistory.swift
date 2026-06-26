import Foundation

/// Keeps the most recent transcriptions in memory so the user can recover text
/// if pasting into the focused app failed. Not persisted across launches.
final class TranscriptionHistory {
    struct Entry {
        let text: String
        let date: Date
    }

    private let maxEntries = 5
    private var entries: [Entry] = []
    private let lock = NSLock()

    /// Record a finished transcription (most recent first). Empty text is ignored.
    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        entries.insert(Entry(text: trimmed, date: Date()), at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        lock.unlock()
    }

    /// Most recent transcriptions, newest first.
    func recent() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}
