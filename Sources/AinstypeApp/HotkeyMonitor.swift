import AppKit
import CoreGraphics

/// One supported modifier hotkey: its virtual keycode, the generic modifier
/// flag, and the device-specific NX_DEVICE…MASK bits that distinguish the left
/// from the right key of the same family in `modifierFlags.rawValue`.
private struct ModifierKey {
    let keyCode: UInt16
    let modifierFlag: NSEvent.ModifierFlags
    /// Bit identifying exactly this key (e.g. right ⌘) in the raw flags.
    let deviceMask: UInt
    /// Both left+right bits of this key's family, to detect whether the event
    /// carries device-specific information at all.
    let familyMask: UInt
}

/// macOS virtual keycodes and NX device masks for modifier keys.
private let keycodeMap: [String: ModifierKey] = [
    "cmd_r": ModifierKey(keyCode: 54, modifierFlag: .command, deviceMask: 0x10, familyMask: 0x18),
    "cmd": ModifierKey(keyCode: 55, modifierFlag: .command, deviceMask: 0x08, familyMask: 0x18),
    "alt_r": ModifierKey(keyCode: 61, modifierFlag: .option, deviceMask: 0x40, familyMask: 0x60),
    "alt": ModifierKey(keyCode: 58, modifierFlag: .option, deviceMask: 0x20, familyMask: 0x60),
    "ctrl_r": ModifierKey(keyCode: 62, modifierFlag: .control, deviceMask: 0x2000, familyMask: 0x2001),
    "ctrl": ModifierKey(keyCode: 59, modifierFlag: .control, deviceMask: 0x01, familyMask: 0x2001),
]

/// Global hotkey monitor using NSEvent for modifier keys (hold-to-record pattern).
class HotkeyMonitor {
    let keyName: String
    let onPress: () -> Void
    let onRelease: () -> Void

    private let targetKeyCode: UInt16
    private let modifierFlag: NSEvent.ModifierFlags
    private let deviceMask: UInt
    private let familyMask: UInt
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pressed = false
    private let lock = NSLock()

    /// Supported hotkey names (modifier keys only, hold-to-record).
    static var supportedKeys: [String] { Array(keycodeMap.keys) }

    /// Fails (returns nil) if `keyName` is not a supported modifier key, so a bad
    /// config value degrades gracefully instead of crashing the app.
    init?(keyName: String, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        guard let mapping = keycodeMap[keyName] else {
            Logger.error("Unsupported hotkey '\(keyName)'. Supported: \(keycodeMap.keys.joined(separator: ", "))")
            return nil
        }
        self.keyName = keyName
        self.targetKeyCode = mapping.keyCode
        self.modifierFlag = mapping.modifierFlag
        self.deviceMask = mapping.deviceMask
        self.familyMask = mapping.familyMask
        self.onPress = onPress
        self.onRelease = onRelease
    }

    /// Install the event monitors. Returns true on success.
    /// Must be called on the main thread.
    ///
    /// Two monitors are needed: the global monitor sees events in all *other*
    /// apps but explicitly never receives events delivered to this app — so
    /// without the local monitor the hotkey goes dead whenever an ainstype
    /// window (Settings, Dictionary) is focused.
    @discardableResult
    func start() -> Bool {
        if globalMonitor != nil {
            Logger.log("HotkeyMonitor already started")
            return true
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleEvent(event)
        }

        if globalMonitor == nil {
            Logger.error("Failed to create NSEvent monitor — grant Input Monitoring permission")
            return false
        }

        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleEvent(event)
                return event
            }
        }

        Logger.log("Hotkey monitor started (key=\(keyName), keycode=\(targetKeyCode))")
        return true
    }

    /// Remove the event monitors.
    func stop() {
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
            Logger.log("Hotkey monitor stopped")
        }
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
    }

    /// Reset pressed state (e.g. after sleep/wake).
    func reset() {
        lock.lock()
        pressed = false
        lock.unlock()
    }

    var isActive: Bool { globalMonitor != nil }

    private func handleEvent(_ event: NSEvent) {
        processFlagsChange(keyCode: event.keyCode, rawFlags: event.modifierFlags.rawValue)
    }

    /// Core press/release decision, separated from NSEvent so it can be tested
    /// with simulated flag sequences.
    ///
    /// The generic modifier flag (e.g. `.command`) is shared by the left and
    /// right key of a family, so it stays set when the *other* key is still
    /// held — releasing right-⌘ while left-⌘ is down would never be detected
    /// and recording would run until the safety timer. Prefer the
    /// device-specific bit; fall back to the generic flag only when the event
    /// carries no device bits at all (some remapping tools synthesize such
    /// events).
    func processFlagsChange(keyCode: UInt16, rawFlags: UInt) {
        guard keyCode == targetKeyCode else { return }

        let isPressed: Bool
        if rawFlags & familyMask != 0 {
            isPressed = rawFlags & deviceMask != 0
        } else {
            isPressed = NSEvent.ModifierFlags(rawValue: rawFlags).contains(modifierFlag)
        }

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
