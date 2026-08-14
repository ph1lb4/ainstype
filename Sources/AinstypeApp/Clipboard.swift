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

    /// Drop a pending restore so no timer can overwrite the clipboard again.
    /// Used when text is deliberately left on the clipboard for the user to
    /// paste by hand (a failed paste, "Copy Latest", the bubble's Copy button):
    /// restoring their old clipboard over it would throw the text away. Bumping
    /// the generation also neutralizes any timer already in flight.
    mutating func cancelPending() {
        hasPending = false
        pendingValue = nil
        generation += 1
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

    /// Copy `text` and keep it there: cancels any pending restore from an
    /// earlier paste or clipboard hold, which would otherwise fire seconds later
    /// and overwrite it. For text the user must be able to paste by hand.
    static func copyPinned(_ text: String) {
        restoreLedger.withLock { $0.cancelPending() }
        copy(text)
    }

    /// Copy `text`, then restore the previous clipboard after `duration`.
    /// Backs the clipboard-hold setting: the latest transcription stays
    /// pasteable with a manual ⌘V for a while, then the user's own clipboard
    /// comes back. A `duration` of 0 or less pins the text instead of holding it.
    static func copyAndHold(_ text: String, for duration: TimeInterval) {
        guard duration > 0 else { return copyPinned(text) }
        let previous = read()
        copy(text)
        scheduleRestore(previous: previous, after: duration)
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
    ///
    /// `hold` (the clipboard-hold setting) extends how long the text stays on the
    /// clipboard after the paste, so the user can repeat the paste by hand if the
    /// automatic one didn't land where they wanted.
    static func pasteToFocusedApp(_ text: String, holdFor hold: TimeInterval = 0) -> Bool {
        let previous = read()
        copy(text)

        guard postPasteEvent() else {
            // The paste never happened, so ⌘V is the user's only route to this
            // text — leave it on the clipboard and cancel any pending restore.
            restoreLedger.withLock { $0.cancelPending() }
            return false
        }

        scheduleRestore(previous: previous, after: max(restoreDelay, hold))
        return true
    }

    /// Restore `previous` after `delay`. The ledger keeps the original value
    /// across rapid overlapping pastes and lets only the newest one's timer
    /// restore it.
    private static func scheduleRestore(previous: String?, after delay: TimeInterval) {
        let generation = restoreLedger.withLock { $0.recordPaste(previousClipboard: previous) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let value = restoreLedger.withLock({ $0.takeRestore(for: generation) }) {
                copy(value)
            }
        }
    }

    /// Insert `text` into the focused editable element. Used by live mode, which
    /// inserts many small chunks as words are confirmed.
    ///
    /// Live mode normally writes the focused element's selected-text attribute.
    /// That is an atomic insert/selection replacement, preserves boundary spaces,
    /// and leaves the clipboard untouched. It also avoids synthetic keyboard
    /// events while the push-to-talk modifier is physically held.
    ///
    /// Quartz Unicode keyboard events are unsuitable here: application frameworks
    /// may ignore their Unicode payload and translate virtual keycode 0 as `A`
    /// using the physical modifier state. With Right Command held that becomes
    /// Cmd+A and selects the target's contents. If the focused app does not expose
    /// an editable accessibility element, fall back to the regular paste path.
    ///
    /// Returns false only when both routes failed, i.e. the text did not reach
    /// the focused app and has to be recovered by the user.
    @discardableResult
    static func typeText(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        if insertIntoFocusedElement(text) { return true }

        Logger.log("Focused element does not support direct text insertion; using paste fallback")
        return pasteToFocusedApp(text)
    }

    /// Replace the current selection (or the zero-length insertion-point
    /// selection) in the focused editable accessibility element.
    private static func insertIntoFocusedElement(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue
        else { return false }

        let focused = focusedValue as! AXUIElement
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            focused,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success,
        settable.boolValue
        else { return false }

        return AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success
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
