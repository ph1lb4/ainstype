import AppKit
import CoreGraphics

/// macOS virtual keycodes for modifier keys.
private let keycodeMap: [String: (keyCode: UInt16, modifierFlag: NSEvent.ModifierFlags)] = [
    "cmd_r": (54, .command),
    "cmd": (55, .command),
    "alt_r": (61, .option),
    "alt": (58, .option),
    "ctrl_r": (62, .control),
    "ctrl": (59, .control),
]

/// Global hotkey monitor using NSEvent for modifier keys (hold-to-record pattern).
class HotkeyMonitor {
    let keyName: String
    let onPress: () -> Void
    let onRelease: () -> Void

    private let targetKeyCode: UInt16
    private let modifierFlag: NSEvent.ModifierFlags
    private var monitor: Any?
    private var pressed = false
    private let lock = NSLock()

    init(keyName: String, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        guard let mapping = keycodeMap[keyName] else {
            fatalError("Unsupported hotkey: \(keyName). Supported: \(Array(keycodeMap.keys))")
        }
        self.keyName = keyName
        self.targetKeyCode = mapping.keyCode
        self.modifierFlag = mapping.modifierFlag
        self.onPress = onPress
        self.onRelease = onRelease
    }

    /// Install the global event monitor. Returns true on success.
    /// Must be called on the main thread.
    @discardableResult
    func start() -> Bool {
        if monitor != nil {
            Logger.log("HotkeyMonitor already started")
            return true
        }

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleEvent(event)
        }

        if monitor == nil {
            Logger.error("Failed to create NSEvent monitor — grant Input Monitoring permission")
            return false
        }

        Logger.log("Hotkey monitor started (key=\(keyName), keycode=\(targetKeyCode))")
        return true
    }

    /// Remove the global event monitor.
    func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
            Logger.log("Hotkey monitor stopped")
        }
    }

    /// Reset pressed state (e.g. after sleep/wake).
    func reset() {
        lock.lock()
        pressed = false
        lock.unlock()
    }

    var isActive: Bool { monitor != nil }

    private func handleEvent(_ event: NSEvent) {
        guard event.keyCode == targetKeyCode else { return }

        let isPressed = event.modifierFlags.contains(modifierFlag)

        lock.lock()
        let wasPressed = pressed
        pressed = isPressed
        lock.unlock()

        if isPressed && !wasPressed {
            Logger.log("Hotkey \(keyName) PRESSED")
            onPress()
        } else if !isPressed && wasPressed {
            Logger.log("Hotkey \(keyName) RELEASED")
            onRelease()
        }
    }
}

// MARK: - Permission Checks

func checkInputMonitoring() -> Bool {
    CGPreflightListenEventAccess()
}

func requestInputMonitoring() -> Bool {
    CGRequestListenEventAccess()
}
