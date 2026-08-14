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
    /// Set when a live chunk could not be inserted into the focused app, so the
    /// whole transcript can be offered for recovery once the session ends.
    private var liveInsertFailed = false

    /// Whether phase-1 model load has completed. Needed so permission warnings
    /// and the model-loading state don't overwrite each other in the menu bar.
    private var modelReady = false

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

        // Copy the latest transcription (recover text if pasting failed)
        let copyLatestItem = NSMenuItem(title: "Copy Latest", action: #selector(copyLatest), keyEquivalent: "")
        copyLatestItem.target = self
        menu.addItem(copyLatestItem)

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
        recorder.inputDevice = InputDeviceSelection(configValue: config.recording.inputDevice)

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
                            self?.modelReady = true
                            // Don't show "Ready" over an unresolved permission
                            // warning — the hotkey wouldn't actually work.
                            if self?.hotkeyMonitor?.isActive == true {
                                self?.updateState(.idle)
                            } else {
                                self?.updateState(.warning("Grant Input Monitoring permission"))
                            }
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

        // A bubble from the previous dictation has served its purpose once the
        // next one starts — and it must not sit over the app being dictated into.
        RecoveryBubble.dismiss()

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
            // Live insertion also requires auto-paste: with auto_paste=false the
            // user chose clipboard-only output, so nothing may be typed.
            if config.liveInsertionEnabled {
                startLiveLoop()
            }
        } catch {
            Logger.error("Failed to start recording: \(error)")
            lock.lock()
            isRecording = false
            lock.unlock()
            RecoveryBubble.present(
                title: "Couldn\u{2019}t start recording",
                message: "Check microphone access in System Settings \u{2192} Privacy & Security \u{2192} Microphone."
            )
        }
    }

    private func onHotkeyRelease() {
        lock.lock()
        guard isRecording else { lock.unlock(); return }
        isRecording = false
        lock.unlock()

        DispatchQueue.main.async { self.cancelMaxRecordingTimer() }

        if let session = liveSession {
            finishLiveLoop(session)
            return
        }

        let audio = recorder.stop()
        DispatchQueue.main.async { self.updateState(.processing) }

        Task {
            do {
                if audio.isEmpty {
                    Logger.log("Empty audio buffer")
                    RecoveryBubble.present(
                        title: "Nothing was recorded",
                        message: "No audio was captured. Check microphone access and the selected input device."
                    )
                } else {
                    try await pipeline.processAudio(audio, config: config)
                }
            } catch {
                Logger.error("Pipeline error: \(error)")
                let message = (error as? LocalizedError)?.errorDescription ?? "Transcription failed. Please try again."
                RecoveryBubble.present(title: "Transcription failed", message: message)
            }
            self.finishProcessing()
        }
    }

    // MARK: - Live Transcription Loop

    /// Periodically transcribe the growing buffer and type newly-confirmed text.
    private func startLiveLoop() {
        let session = pipeline.makeLiveSession(config: config)
        liveSession = session
        liveInsertFailed = false

        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // ~1s cadence
                if Task.isCancelled { break }
                guard let self else { break }
                let samples = self.recorder.currentSamples()
                guard !samples.isEmpty else { continue }
                do {
                    if let chunk = try await session.ingest(samples), !chunk.isEmpty {
                        // Report insertion failures once at the end of the
                        // session with the whole transcript, rather than a
                        // bubble per chunk: if one chunk can't be inserted, the
                        // rest of them can't either.
                        if await !Clipboard.typeText(chunk) { self.liveInsertFailed = true }
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
            var finishError: String?
            do {
                if let tail = try await session.finish(audio), !tail.isEmpty {
                    if await !Clipboard.typeText(tail) { liveInsertFailed = true }
                }
                // Privacy: log only sizes, never content.
                Logger.log("Live session done: typed \(session.transcript.count) characters total")
            } catch {
                Logger.error("Live finish error: \(error)")
                finishError = (error as? LocalizedError)?.errorDescription
                    ?? "The final part of the transcription could not be decoded."
                // The final pass failed, but words held back for a possible
                // cross-chunk replacement must still come out.
                if let held = session.flushPending(), !held.isEmpty {
                    if await !Clipboard.typeText(held) { liveInsertFailed = true }
                }
            }
            let transcript = session.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            pipeline.history.add(transcript)
            reportLiveOutcome(transcript: transcript, finishError: finishError)
            self.finishProcessing()
        }
    }

    /// After a live session: surface anything that went wrong in a bubble the
    /// user can copy from, and apply the clipboard hold to the finished
    /// transcript.
    ///
    /// The hold covers the *whole transcript once*, never the individual chunks:
    /// parking each chunk on the clipboard for seconds while the user is still
    /// dictating trampled whatever they had copied.
    private func reportLiveOutcome(transcript: String, finishError: String?) {
        if liveInsertFailed {
            liveInsertFailed = false
            Clipboard.copyPinned(transcript)
            RecoveryBubble.present(
                title: "Couldn\u{2019}t insert text into the app",
                message: transcript,
                copyText: transcript.isEmpty ? nil : transcript,
                note: "Nothing was focused that accepts text. It\u{2019}s on your clipboard \u{2014} click into a text field and press \u{2318}V."
            )
            return
        }

        if let finishError {
            RecoveryBubble.present(
                title: "Transcription incomplete",
                message: finishError,
                copyText: transcript.isEmpty ? nil : transcript,
                note: transcript.isEmpty ? nil : "Copy what was transcribed so far."
            )
            return
        }

        // Live mode inserts text directly and leaves the clipboard alone, so the
        // finished transcript has to be put there explicitly for the hold window.
        // Only when the user asked for it — off by default, the clipboard stays
        // untouched throughout.
        let hold = config.clipboardHoldDuration
        if hold > 0, !transcript.isEmpty {
            Clipboard.copyAndHold(transcript, for: hold)
            Logger.log("Live transcript held on clipboard for \(Int(hold))s")
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
                // Only clear the permission warning; never clobber
                // loading/recording/processing/error states.
                if case .warning = currentState {
                    updateState(modelReady ? .idle : .loading)
                }
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
        ensureDictionaryWindow().showWindow(selectTab: DictionaryWindowController.replacementsTabIndex)
    }

    /// Put the most recent transcription back on the clipboard and keep it there,
    /// for when a paste went to the wrong app (or nowhere at all).
    @objc private func copyLatest() {
        guard let latest = pipeline.history.recent().first else {
            RecoveryBubble.present(
                title: "Nothing to copy yet",
                message: "No transcription has been made since ainstype started."
            )
            return
        }
        Clipboard.copyPinned(latest.text)
        pipeline.log("Copied latest transcription (\(latest.text.count) characters) to clipboard")
        RecoveryBubble.present(
            title: "Latest transcription copied",
            message: latest.text,
            note: "Press \u{2318}V to paste it.",
            style: .info
        )
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

}

// MARK: - SettingsDelegate

extension StatusMenuController: SettingsDelegate {
    func settingsCurrentConfig() -> Config { config }

    func settingsDidChangeHotkey(_ key: String) {
        guard HotkeyMonitor.supportedKeys.contains(key), key != config.recording.hotkey else { return }
        // If the old hotkey is physically held right now, its release event will
        // never arrive once the monitor is swapped — finish that recording first.
        onHotkeyRelease()
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

    func settingsDidChangeClipboardHold(_ seconds: Int) {
        guard seconds != config.clipboardHoldSeconds else { return }
        config.clipboardHoldSeconds = seconds
        config.saveUserConfig(key: "clipboard_hold_seconds", value: seconds)
        pipeline.log(seconds > 0
            ? "Clipboard hold set to \(seconds)s"
            : "Clipboard hold disabled")
    }

    func settingsDidChangeInputDevice(_ value: String) {
        guard value != config.recording.inputDevice else { return }
        config.recording.inputDevice = value
        config.saveUserConfig(key: "recording.input_device", value: value)
        recorder.inputDevice = InputDeviceSelection(configValue: value)
        pipeline.log("Input device set to \(value)")
    }
}
