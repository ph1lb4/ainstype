import AppKit
import CoreGraphics
import ApplicationServices
import os

/// Bookkeeping for restoring the user's clipboard after synthetic pastes.
/// Restores are delayed (see `Clipboard.restoreDelay`), so two dictations in
/// quick succession overlap: the second paste sees *our* transcription as the
/// "previous" clipboard, and the first restore could fire mid-paste. The ledger
/// keeps the original user clipboard across overlapping pastes and only lets
/// the latest paste's timer restore it.
struct RestoreLedger {
    private(set) var generation = 0
    private var hasPending = false
    private var pendingValue: String?

    /// Record a paste about to happen; `previousClipboard` is what the
    /// clipboard held just before. Returns a generation token for `takeRestore`.
    /// While a restore is pending, the clipboard holds *our* transcription, so
    /// only the first overlapping paste captures the user's real clipboard.
    mutating func recordPaste(previousClipboard: String?) -> Int {
        if !hasPending {
            hasPending = true
            pendingValue = previousClipboard
        }
        generation += 1
        return generation
    }

    /// The value the timer for paste `generation` should restore, or nil to do
    /// nothing (superseded by a newer paste, nothing pending, or the original
    /// clipboard was empty).
    mutating func takeRestore(for generation: Int) -> String? {
        guard generation == self.generation, hasPending else { return nil }
        hasPending = false
        defer { pendingValue = nil }
        return pendingValue
    }
}

enum Clipboard {
    /// Virtual keycode for the V key (Cmd+V paste).
    private static let vKeyCode: CGKeyCode = 9

    /// How long to wait before restoring the user's previous clipboard after a
    /// synthetic paste. This is a best-effort race: the synthetic Cmd+V is delivered
    /// asynchronously, so we must wait long enough for the focused app to read the
    /// pasteboard before we overwrite it. Too short and a slow app (e.g. Electron)
    /// pastes the *restored* value instead; too long and the user's clipboard is
    /// "wrong" for a noticeable window. 0.3s balances both for typical apps.
    static let restoreDelay: TimeInterval = 0.3

    /// Copy text to the system clipboard.
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Read current clipboard contents.
    static func read() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// Post a synthetic Cmd+V to the focused app. Returns false if the events
    /// couldn't be created. Note: a `true` return only means the events were posted,
    /// not that the target app accepted them.
    @discardableResult
    private static func postPasteEvent() -> Bool {
        let source = CGEventSource(stateID: CGEventSourceStateID.hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else {
            Logger.error("Failed to create CGEvent for paste")
            return false
        }

        keyDown.flags = CGEventFlags.maskCommand
        keyUp.flags = CGEventFlags.maskCommand

        keyDown.post(tap: CGEventTapLocation.cghidEventTap)
        keyUp.post(tap: CGEventTapLocation.cghidEventTap)
        return true
    }

    private static let restoreLedger = OSAllocatedUnfairLock(initialState: RestoreLedger())

    /// Copy text to clipboard, simulate Cmd+V paste, then restore previous clipboard.
    static func pasteToFocusedApp(_ text: String) -> Bool {
        let previous = read()
        copy(text)

        guard postPasteEvent() else { return false }

        // Restore the user's clipboard after the paste has had time to land.
        // The ledger keeps the original value across rapid overlapping pastes
        // and lets only the newest paste's timer restore it.
        let generation = restoreLedger.withLock { $0.recordPaste(previousClipboard: previous) }
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            if let value = restoreLedger.withLock({ $0.takeRestore(for: generation) }) {
                copy(value)
            }
        }

        return true
    }

    /// Insert `text` by synthesizing per-character key events, the way a text
    /// expander does — NOT via the pasteboard. Used by live mode, which inserts
    /// many small chunks as words are confirmed.
    ///
    /// Live mode cannot paste: Slack and other Electron / rich-text editors strip
    /// whitespace at both edges of every paste, so a space between two separately
    /// pasted chunks always vanishes and the words merge (`therevised`,
    /// `shouldwork`). Typed characters go through the normal keyboard-input path,
    /// so their spaces survive everywhere. Typing also leaves the clipboard
    /// untouched, so live mode no longer needs to save/restore it.
    ///
    /// The push-to-talk hotkey is a modifier key (⌘/⌥/⌃) that is physically held
    /// for the whole dictation, so every synthesized keystroke must be emitted
    /// with NO modifier flags — otherwise the held ⌘ combines with each letter
    /// into a shortcut (`t` → ⌘T opens a browser tab). Two safeguards ensure a
    /// clean event: a private-state source carries no hardware-modifier state to
    /// inherit, and each event's flags are explicitly cleared.
    static func typeText(_ text: String) {
        let source = CGEventSource(stateID: CGEventSourceStateID.privateState)
        // One character per event is the most broadly compatible approach; some
        // apps only accept the first character of a multi-character unicode event.
        for character in text {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                Logger.error("Failed to create CGEvent for typing")
                return
            }

            var units = Array(String(character).utf16)
            keyDown.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            keyUp.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)

            // Strip any inherited modifier flags so the held hotkey can't turn
            // this keystroke into a shortcut.
            keyDown.flags = CGEventFlags(rawValue: 0)
            keyUp.flags = CGEventFlags(rawValue: 0)

            keyDown.post(tap: CGEventTapLocation.cghidEventTap)
            keyUp.post(tap: CGEventTapLocation.cghidEventTap)
        }
    }

    /// Check if the app has Accessibility permission (needed for CGEvent paste).
    static func checkAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompt for Accessibility permission.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
