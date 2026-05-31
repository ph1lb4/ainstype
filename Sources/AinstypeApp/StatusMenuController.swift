import AppKit

/// Manages the NSStatusItem, menu, and UI state.
class StatusMenuController {
    enum State {
        case setup          // first run, waiting for user to start download
        case downloading(progress: Double)
        case loading        // loading model into memory
        case idle
        case recording
        case processing
        case warning(String)
        case error(String)
    }

    private var config: Config
    private let pipeline: Pipeline
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var startAtLoginItem: NSMenuItem!
    private var dictionaryWindowController: DictionaryWindowController?
    private var setupWindowController: SetupWindowController?
    private var hotkeyMonitor: HotkeyMonitor?
    private var recorder: AudioRecorder!
    private var healthTimer: Timer?
    private var currentState: State = .setup
    private var isRecording = false
    private let lock = NSLock()

    init(config: Config, pipeline: Pipeline) {
        self.config = config
        self.pipeline = pipeline
    }

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "ainstype")
        }

        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Starting up…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        // Dictionary
        let dictItem = NSMenuItem(title: "Dictionary\u{2026}", action: #selector(openDictionary), keyEquivalent: "")
        dictItem.target = self
        menu.addItem(dictItem)

        // Start at Login
        startAtLoginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
        startAtLoginItem.target = self
        startAtLoginItem.state = LaunchAgent.isInstalled ? .on : .off
        menu.addItem(startAtLoginItem)

        // Permissions
        let permItem = NSMenuItem(title: "Check Permissions…", action: #selector(checkPermissions), keyEquivalent: "")
        permItem.target = self
        menu.addItem(permItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        // Create recorder
        recorder = AudioRecorder(sampleRate: config.recording.sampleRate)

        // Start hotkey monitor
        startHotkeyMonitor()

        // Health check timer
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }

        // Check if first run and show setup or start loading
        if pipeline.hasCachedModel {
            updateState(.loading)
            startModelInit()
        } else {
            showFirstRunSetup()
        }
    }

    // MARK: - First Run

    private func showFirstRunSetup() {
        updateState(.setup)
        let setup = SetupWindowController()
        setup.show()
        setupWindowController = setup
        startModelInit()
    }

    private func startModelInit() {
        Task {
            await pipeline.warmUp(
                progress: { [weak self] pct in
                    DispatchQueue.main.async {
                        self?.updateState(.downloading(progress: pct))
                        self?.setupWindowController?.updateForDownload(progress: pct)
                    }
                },
                status: { [weak self] status in
                    DispatchQueue.main.async {
                        switch status {
                        case "ready":
                            self?.updateState(.idle)
                            // Warm CoreAudio so the first hotkey press isn't cold-slow.
                            // The engine is constructed and immediately released inside
                            // prewarm() to avoid keeping the mic AU open.
                            self?.recorder.prewarm()
                            if let setup = self?.setupWindowController {
                                setup.updateForReady()
                                setup.onDismiss = { [weak self] in
                                    self?.setupWindowController = nil
                                }
                            }
                        case "error":
                            self?.updateState(.error("Model failed to load"))
                            self?.setupWindowController?.close()
                        default:
                            self?.updateState(.loading)
                        }
                    }
                }
            )
        }
    }

    // MARK: - State

    func updateState(_ state: State) {
        currentState = state
        switch state {
        case .setup:
            setIcon("arrow.down.circle")
            statusMenuItem.title = "Setup required…"

        case .downloading(let progress):
            let pct = Int(progress * 100)
            setIcon("arrow.down.circle")
            statusMenuItem.title = "Downloading model… \(pct)%"

        case .loading:
            setIcon("hourglass")
            statusMenuItem.title = "Loading model…"

        case .idle:
            setIcon("mic.fill")
            statusMenuItem.title = "Status: Ready"

        case .recording:
            setIcon("record.circle")
            statusMenuItem.title = "Status: Recording…"

        case .processing:
            setIcon("hourglass")
            statusMenuItem.title = "Status: Processing…"

        case .warning(let msg):
            setIcon("exclamationmark.triangle")
            statusMenuItem.title = "Warning: \(msg)"

        case .error(let msg):
            setIcon("xmark.circle")
            statusMenuItem.title = "Error: \(msg)"
        }
    }

    private func setIcon(_ symbolName: String) {
        statusItem.button?.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "ainstype"
        )
    }

    // MARK: - Hotkey Callbacks

    private var modelReady: Bool {
        if case .idle = currentState { return true }
        if case .recording = currentState { return true }
        if case .processing = currentState { return true }
        return false
    }

    private func onHotkeyPress() {
        guard modelReady else { return }

        lock.lock()
        guard !isRecording else { lock.unlock(); return }
        isRecording = true
        lock.unlock()

        do {
            try recorder.start()
            DispatchQueue.main.async { self.updateState(.recording) }
        } catch {
            Logger.error("Failed to start recording: \(error)")
            lock.lock()
            isRecording = false
            lock.unlock()
        }
    }

    private func onHotkeyRelease() {
        lock.lock()
        guard isRecording else { lock.unlock(); return }
        isRecording = false
        lock.unlock()

        let audio = recorder.stop()
        DispatchQueue.main.async { self.updateState(.processing) }

        Task {
            do {
                if audio.isEmpty {
                    Logger.log("Empty audio buffer")
                    await showNotification(title: "ainstype", body: "Recording was empty. Check mic permissions.")
                } else {
                    try await pipeline.processAudio(audio, config: config)
                }
            } catch {
                Logger.error("Pipeline error: \(error)")
                await showNotification(title: "ainstype Error", body: String(describing: error).prefix(200).description)
            }
            DispatchQueue.main.async { self.updateState(.idle) }
        }
    }

    // MARK: - Hotkey Monitor

    private func startHotkeyMonitor() {
        hotkeyMonitor = HotkeyMonitor(
            keyName: config.recording.hotkey,
            onPress: { [weak self] in self?.onHotkeyPress() },
            onRelease: { [weak self] in self?.onHotkeyRelease() }
        )

        if hotkeyMonitor!.start() { return }

        // Monitor failed — request permission (adds app to System Settings list)
        Logger.log("Monitor failed to start, requesting Input Monitoring permission...")
        _ = requestInputMonitoring()

        // Retry once after requesting
        if hotkeyMonitor!.start() { return }

        // Still failed — warn in menu bar but don't show a blocking alert.
        // Debug builds often fail this check despite permission being granted.
        // The health check timer will retry every 30s.
        Logger.log("Input Monitoring: monitor not started (will retry via health check)")
        updateState(.warning("Grant Input Monitoring permission"))
    }

    private func checkHealth() {
        guard let monitor = hotkeyMonitor else { return }
        if !monitor.isActive {
            Logger.log("Hotkey monitor not active, attempting restart")
            if monitor.start() {
                Logger.log("Hotkey monitor recovered")
                updateState(.idle)
            }
        }
    }

    // MARK: - Sleep/Wake

    func handleWake() {
        hotkeyMonitor?.reset()

        lock.lock()
        let wasRecording = isRecording
        isRecording = false
        lock.unlock()

        if wasRecording {
            _ = recorder.stop()
            updateState(.idle)
        }
    }

    // MARK: - Menu Actions

    @objc private func toggleStartAtLogin() {
        do {
            if LaunchAgent.isInstalled {
                try LaunchAgent.uninstall()
                startAtLoginItem.state = .off
                pipeline.log("Auto-launch disabled")
            } else {
                try LaunchAgent.install()
                startAtLoginItem.state = .on
                pipeline.log("Auto-launch enabled")
            }
        } catch {
            Logger.error("LaunchAgent toggle failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "Failed to update login item"
            alert.informativeText = String(describing: error)
            alert.runModal()
        }
    }

    @objc private func openDictionary() {
        if dictionaryWindowController == nil {
            dictionaryWindowController = DictionaryWindowController(dictionary: pipeline.dictionary)
        }
        dictionaryWindowController!.showWindow()
    }

    @objc private func checkPermissions() {
        let hasInput = hotkeyMonitor?.isActive ?? false
        let hasAccessibility = Clipboard.checkAccessibility()

        var lines: [String] = []
        lines.append("Input Monitoring: \(hasInput ? "✓ Active" : "✗ NOT ACTIVE")")
        lines.append("Accessibility: \(hasAccessibility ? "✓ Granted" : "✗ NOT GRANTED")")

        if !hasInput {
            startHotkeyMonitor()
            if hotkeyMonitor?.isActive == true {
                lines.append("\nHotkey monitor restarted.")
            }
        }

        let alert = NSAlert()
        alert.messageText = "Permission Status"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() {
        hotkeyMonitor?.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Notifications

    private func showNotification(title: String, body: String) async {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        NSUserNotificationCenter.default.deliver(notification)
    }
}
