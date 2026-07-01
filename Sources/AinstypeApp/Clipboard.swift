import AppKit
import CoreGraphics
import ApplicationServices

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

    /// Copy text to clipboard, simulate Cmd+V paste, then restore previous clipboard.
    static func pasteToFocusedApp(_ text: String) -> Bool {
        let previous = read()
        copy(text)

        guard postPasteEvent() else { return false }

        // Restore previous clipboard after the paste has had time to land.
        if let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
                copy(previous)
            }
        }

        return true
    }

    /// Copy text and simulate Cmd+V, WITHOUT saving/restoring the clipboard.
    /// Used by live mode where many chunks are pasted in sequence; the caller is
    /// responsible for restoring the user's original clipboard once at the end.
    ///
    /// Any leading whitespace — the only thing separating this chunk from the
    /// previously pasted word — is typed as real keystrokes instead of pasted.
    /// Several text engines (web & Electron inputs, rich-text `NSTextView`s with
    /// smart copy/paste) silently strip leading whitespace from pasted content,
    /// which would merge this chunk into the previous word. Terminals and plain
    /// native fields paste it raw, which is why the merge only shows up in some
    /// apps. Typed keystrokes go through the normal input path and survive
    /// everywhere.
    static func pasteChunk(_ text: String) {
        let leading = text.prefix { $0 == " " }
        let body = String(text.dropFirst(leading.count))
        if !leading.isEmpty { typeText(String(leading)) }
        guard !body.isEmpty else { return }
        copy(body)
        postPasteEvent()
    }

    /// Insert `text` as synthetic Unicode key events (not a paste), so it goes
    /// through the normal keyboard-input path rather than the pasteboard.
    static func typeText(_ text: String) {
        let source = CGEventSource(stateID: CGEventSourceStateID.hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            Logger.error("Failed to create CGEvent for typing")
            return
        }

        var utf16 = Array(text.utf16)
        keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)

        keyDown.post(tap: CGEventTapLocation.cghidEventTap)
        keyUp.post(tap: CGEventTapLocation.cghidEventTap)
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
