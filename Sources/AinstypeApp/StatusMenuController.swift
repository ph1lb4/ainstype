import AppKit
import UserNotifications

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
    private var liveTranscriptionItem: NSMenuItem!
    private var dictionaryWindowController: DictionaryWindowController?
    private var setupWindowController: SetupWindowController?
    private var hotkeyMonitor: HotkeyMonitor?
    private var recorder: AudioRecorder!
    private var healthTimer: Timer?
    private var maxRecordingTimer: Timer?
    private var currentState: State = .setup
    private var isRecording = false
    private let lock = NSLock()

    /// Safety stop: if a hotkey key-up is ever missed (focus switch, monitor
    /// restart mid-hold), recording would otherwise run — and hold the mic open —
    /// forever. Auto-stop after this long.
    private let maxRecordingDuration: TimeInterval = 120

    // Live (streaming) transcription state
    private var liveSession: LiveSession?
    private var liveTask: Task<Void, Never>?

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

        // Settings
        let settingsItem = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Dictionary
        let dictItem = NSMenuItem(title: "Dictionary\u{2026}", action: #selector(openDictionary), keyEquivalent: "")
        dictItem.target = self
        menu.addItem(dictItem)

        // Recent transcriptions (recover text if pasting failed)
        let historyItem = NSMenuItem(title: "Recent Transcriptions\u{2026}", action: #selector(openHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        // Start at Login
        startAtLoginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
        startAtLoginItem.target = self
        startAtLoginItem.state = LaunchAgent.isInstalled ? .on : .off
        menu.addItem(startAtLoginItem)

        // Live transcription (paste incrementally while recording)
        liveTranscriptionItem = NSMenuItem(title: "Live Transcription", action: #selector(toggleLiveTranscription), keyEquivalent: "")
        liveTranscriptionItem.target = self
        liveTranscriptionItem.state = config.liveTranscription ? .on : .off
        menu.addItem(liveTranscriptionItem)

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

        // Ask for permission to post our error/empty-recording notifications.
        requestNotificationAuthorization()

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
                                // First run: proactively request the permissions paste
                                // needs, so the very first transcription actually lands
                                // instead of silently falling back to copy-only.
                                self?.requestFirstRunPermissions()
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

    /// Recording may only begin from `.idle`. Allowing it during `.processing`
    /// previously let a second recording start mid-transcription, after which the
    /// first run's completion would clobber state back to `.idle` and two
    /// transcriptions could race on the one WhisperKit instance.
    private var canStartRecording: Bool {
        if case .idle = currentState { return true }
        return false
    }

    private func onHotkeyPress() {
        guard canStartRecording else { return }

        lock.lock()
        guard !isRecording else { lock.unlock(); return }
        isRecording = true
        lock.unlock()

        do {
            try recorder.start()
            DispatchQueue.main.async {
                self.updateState(.recording)
                self.startMaxRecordingTimer()
            }
            if config.liveTranscription {
                startLiveLoop()
            }
        } catch {
            Logger.error("Failed to start recording: \(error)")
            lock.lock()
            isRecording = false
            lock.unlock()
            Task { await self.showNotification(
                title: "ainstype",
                body: "Couldn't start recording. Check microphone access in System Settings → Privacy & Security."
            ) }
        }
    }

    private func onHotkeyRelease() {
        lock.lock()
        guard isRecording else { lock.unlock(); return }
        isRecording = false
        lock.unlock()

        DispatchQueue.main.async { self.cancelMaxRecordingTimer() }

        if config.liveTranscription, let session = liveSession {
            finishLiveLoop(session)
            return
        }

        let audio = recorder.stop()
        DispatchQueue.main.async { self.updateState(.processing) }

        Task {
            do {
                if audio.isEmpty {
                    Logger.log("Empty audio buffer")
                    await showNotification(title: "ainstype", body: "Recording was empty — nothing was captured. Check microphone access.")
                } else {
                    try await pipeline.processAudio(audio, config: config)
                }
            } catch {
                Logger.error("Pipeline error: \(error)")
                let message = (error as? LocalizedError)?.errorDescription ?? "Transcription failed. Please try again."
                await showNotification(title: "ainstype", body: message)
            }
            self.finishProcessing()
        }
    }

    // MARK: - Live Transcription Loop

    /// Periodically transcribe the growing buffer and type newly-confirmed text.
    private func startLiveLoop() {
        let session = pipeline.makeLiveSession(config: config)
        liveSession = session

        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // ~1s cadence
                if Task.isCancelled { break }
                guard let self else { break }
                let samples = self.recorder.currentSamples()
                guard !samples.isEmpty else { continue }
                do {
                    if let chunk = try await session.ingest(samples), !chunk.isEmpty {
                        Clipboard.typeText(chunk)
                    }
                } catch {
                    Logger.error("Live ingest error: \(error)")
                }
            }
        }
    }

    /// Stop the live loop and type the remaining tail.
    private func finishLiveLoop(_ session: LiveSession) {
        let task = liveTask
        liveTask = nil
        liveSession = nil
        task?.cancel()

        let audio = recorder.stop()
        DispatchQueue.main.async { self.updateState(.processing) }

        Task {
            // Wait for any in-flight ingest to finish so the final pass sees the
            // up-to-date confirmed point and we never emit duplicate text.
            await task?.value
            do {
                if let tail = try await session.finish(audio), !tail.isEmpty {
                    Clipboard.typeText(tail)
                }
            } catch {
                Logger.error("Live finish error: \(error)")
            }
            pipeline.history.add(session.transcript.trimmingCharacters(in: .whitespacesAndNewlines))
            self.finishProcessing()
        }
    }

    /// Return to `.idle` after processing, but only if we're still in `.processing`
    /// — never clobber a `.recording`/`.error`/`.warning` state set in the meantime.
    private func finishProcessing() {
        DispatchQueue.main.async {
            if case .processing = self.currentState { self.updateState(.idle) }
        }
    }

    // MARK: - Recording Safety Timer

    private func startMaxRecordingTimer() {
        cancelMaxRecordingTimer()
        maxRecordingTimer = Timer.scheduledTimer(withTimeInterval: maxRecordingDuration, repeats: false) { [weak self] _ in
            Logger.log("Max recording duration reached — auto-stopping")
            self?.onHotkeyRelease()
        }
    }

    private func cancelMaxRecordingTimer() {
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil
    }

    // MARK: - Hotkey Monitor

    private func startHotkeyMonitor() {
        if hotkeyMonitor == nil {
            hotkeyMonitor = HotkeyMonitor(
                keyName: config.recording.hotkey,
                onPress: { [weak self] in self?.onHotkeyPress() },
                onRelease: { [weak self] in self?.onHotkeyRelease() }
            )
        }

        // Config.validate() guarantees a supported hotkey, so this normally succeeds.
        guard let monitor = hotkeyMonitor else {
            Logger.error("Hotkey monitor unavailable for '\(config.recording.hotkey)'")
            updateState(.error("Unsupported hotkey: \(config.recording.hotkey)"))
            return
        }

        if monitor.start() { return }

        // Monitor failed — request permission (adds app to System Settings list)
        Logger.log("Monitor failed to start, requesting Input Monitoring permission...")
        _ = requestInputMonitoring()

        // Retry once after requesting
        if monitor.start() { return }

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
        cancelMaxRecordingTimer()

        lock.lock()
        let wasRecording = isRecording
        isRecording = false
        lock.unlock()

        if wasRecording {
            liveTask?.cancel()
            liveTask = nil
            liveSession = nil
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

    @objc private func toggleLiveTranscription() {
        settingsDidToggleLiveTranscription(!config.liveTranscription)
    }

    @objc private func openSettings() {
        ensureDictionaryWindow().showWindow(selectTab: DictionaryWindowController.settingsTabIndex)
    }

    @objc private func openDictionary() {
        ensureDictionaryWindow().showWindow(selectTab: DictionaryWindowController.wordsTabIndex)
    }

    @objc private func openHistory() {
        ensureDictionaryWindow().showWindow(selectTab: DictionaryWindowController.historyTabIndex)
    }

    private func ensureDictionaryWindow() -> DictionaryWindowController {
        if dictionaryWindowController == nil {
            let controller = DictionaryWindowController(
                dictionary: pipeline.dictionary,
                history: pipeline.history
            )
            controller.settingsDelegate = self
            dictionaryWindowController = controller
        }
        return dictionaryWindowController!
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

        if !hasAccessibility {
            Clipboard.requestAccessibility()
            lines.append("\nRequested Accessibility — grant it in System Settings, then reopen this app.")
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

    // MARK: - Permissions

    /// First-run: request the permissions the paste path needs up front so the
    /// first transcription lands instead of silently falling back to copy-only.
    private func requestFirstRunPermissions() {
        AudioRecorder.requestPermission { _ in }
        if !Clipboard.checkAccessibility() {
            Clipboard.requestAccessibility()
        }
    }

    // MARK: - Notifications

    private func requestNotificationAuthorization() {
        // UNUserNotificationCenter requires a real app bundle; skip under `swift run`.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { Logger.error("Notification authorization failed: \(error)") }
        }
    }

    private func showNotification(title: String, body: String) async {
        guard Bundle.main.bundleIdentifier != nil else {
            Logger.log("Notification (no bundle): \(title) — \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Logger.error("Failed to deliver notification: \(error)")
        }
    }
}

// MARK: - SettingsDelegate

extension StatusMenuController: SettingsDelegate {
    func settingsCurrentConfig() -> Config { config }

    func settingsDidChangeHotkey(_ key: String) {
        guard HotkeyMonitor.supportedKeys.contains(key), key != config.recording.hotkey else { return }
        hotkeyMonitor?.stop()
        hotkeyMonitor = nil
        config.recording.hotkey = key
        config.saveUserConfig(key: "recording.hotkey", value: key)
        startHotkeyMonitor()
        pipeline.log("Hotkey changed to \(key)")
    }

    func settingsDidChangeLanguage(_ language: String?) {
        guard language != config.language else { return }
        config.language = language
        config.saveUserConfig(key: "language", value: language ?? "")
        pipeline.log("Language set to \(language ?? "auto-detect")")
    }

    func settingsDidToggleLiveTranscription(_ enabled: Bool) {
        config.liveTranscription = enabled
        liveTranscriptionItem.state = enabled ? .on : .off
        config.saveUserConfig(key: "live_transcription", value: enabled)
        pipeline.log("Live transcription \(enabled ? "enabled" : "disabled")")
    }

    func settingsDidChangeLiveMode(_ mode: LiveMode) {
        guard mode != config.liveMode else { return }
        config.liveMode = mode
        config.saveUserConfig(key: "live_mode", value: mode.rawValue)
        pipeline.log("Live mode set to \(mode.rawValue)")
    }
}
