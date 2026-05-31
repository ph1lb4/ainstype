import AppKit
import CoreGraphics
import ApplicationServices

enum Clipboard {
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

    /// Copy text to clipboard, simulate Cmd+V paste, then restore previous clipboard.
    static func pasteToFocusedApp(_ text: String) -> Bool {
        let previous = read()
        copy(text)

        let source = CGEventSource(stateID: CGEventSourceStateID.hidSystemState)

        // Key code 9 = V
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else {
            Logger.error("Failed to create CGEvent for paste")
            return false
        }

        keyDown.flags = CGEventFlags.maskCommand
        keyUp.flags = CGEventFlags.maskCommand

        keyDown.post(tap: CGEventTapLocation.cghidEventTap)
        keyUp.post(tap: CGEventTapLocation.cghidEventTap)

        // Restore previous clipboard after a short delay
        if let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }

        return true
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
