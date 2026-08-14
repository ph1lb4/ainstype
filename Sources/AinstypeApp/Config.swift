import Foundation
import TOMLKit

struct RecordingConfig {
    var hotkey: String = "cmd_r"
    var sampleRate: Int = 16000
    /// Which microphone to capture from, as an `InputDeviceSelection` config
    /// value ("default", "builtin", or a device UID). Defaults to the system
    /// default input; set it to "builtin" in Settings to keep Bluetooth
    /// headphones out of call mode while recording.
    var inputDevice: String = "default"
}

struct TranscriptionConfig {
    var model: String = "openai_whisper-large-v3-v20240930_turbo_632MB"
}

/// Granularity at which live transcription commits text to the focused app.
/// `sentence` waits for a whole segment/phrase (smoother, appears in natural
/// chunks); `word` commits each word as it's confirmed (snappier first output,
/// but types in rapid bursts).
enum LiveMode: String {
    case sentence
    case word
}

struct Config {
    var language: String? = nil
    var autoPaste: Bool = true
    var verbose: Bool = false
    /// When true, insert confirmed text incrementally while recording (live mode)
    /// instead of inserting everything once on hotkey release. On by default.
    var liveTranscription: Bool = true
    /// Granularity of live insertion. Defaults to sentence (smoother).
    var liveMode: LiveMode = .sentence
    /// How long the latest transcription is kept on the clipboard before the
    /// user's previous clipboard content is restored, in seconds. 0 (the default)
    /// keeps the old behaviour: the clipboard is restored as soon as the
    /// automatic paste has landed. Set to 5 or 10 in Settings to always have a
    /// window in which a manual ⌘V pastes what was just dictated.
    var clipboardHoldSeconds: Int = 0

    /// `clipboardHoldSeconds` as a duration, clamped to non-negative.
    var clipboardHoldDuration: TimeInterval { TimeInterval(max(0, clipboardHoldSeconds)) }

    /// Whether recording should insert text live (type-as-you-speak). Requires
    /// both the live toggle and auto-paste: with auto_paste off the user chose
    /// clipboard-only output, so nothing may be typed into the focused app.
    var liveInsertionEnabled: Bool { liveTranscription && autoPaste }
    var recording: RecordingConfig = RecordingConfig()
    var transcription: TranscriptionConfig = TranscriptionConfig()

    static let configDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/ainstype")

    var dictionaryPath: URL { Config.configDir.appendingPathComponent("dictionary.toml") }
    var configPath: URL { Config.configDir.appendingPathComponent("config.toml") }

    /// Load config with precedence: env vars > user config > defaults.
    static func load() -> Config {
        var config = Config()

        // Load default.toml from bundle or known path
        let defaultPaths = [
            Bundle.main.url(forResource: "default", withExtension: "toml"),
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("config/default.toml"),
        ].compactMap { $0 }

        for path in defaultPaths {
            if let data = try? String(contentsOf: path, encoding: .utf8) {
                config.applyTOML(data)
                break
            }
        }

        // Load user config
        let userConfig = configDir.appendingPathComponent("config.toml")
        if let data = try? String(contentsOf: userConfig, encoding: .utf8) {
            config.applyTOML(data)
        }

        config.validate()
        return config
    }

    /// Clamp/repair values that would otherwise crash or silently break the app.
    /// Internal rather than private so tests can exercise the clamping directly.
    mutating func validate() {
        if !HotkeyMonitor.supportedKeys.contains(recording.hotkey) {
            Logger.error("Invalid hotkey '\(recording.hotkey)' in config — falling back to 'cmd_r'. Supported: \(HotkeyMonitor.supportedKeys.joined(separator: ", "))")
            recording.hotkey = "cmd_r"
        }
        if recording.sampleRate <= 0 {
            Logger.error("Invalid sample_rate \(recording.sampleRate) in config — falling back to 16000")
            recording.sampleRate = 16000
        }
        // A hold longer than this would leave the user's own clipboard replaced
        // for so long that it reads as a bug rather than a feature.
        if clipboardHoldSeconds < 0 || clipboardHoldSeconds > Config.maxClipboardHoldSeconds {
            Logger.error("Invalid clipboard_hold_seconds \(clipboardHoldSeconds) in config — clamping to 0…\(Config.maxClipboardHoldSeconds)")
            clipboardHoldSeconds = min(max(0, clipboardHoldSeconds), Config.maxClipboardHoldSeconds)
        }
    }

    /// Upper bound for `clipboardHoldSeconds`.
    static let maxClipboardHoldSeconds = 60

    mutating func applyTOML(_ tomlString: String) {
        guard let table = try? TOMLTable(string: tomlString) else { return }

        if let language = table["language"]?.string { self.language = language.isEmpty ? nil : language }
        if let autoPaste = table["auto_paste"]?.bool { self.autoPaste = autoPaste }
        if let verbose = table["verbose"]?.bool { self.verbose = verbose }
        if let live = table["live_transcription"]?.bool { self.liveTranscription = live }
        if let mode = table["live_mode"]?.string, let parsed = LiveMode(rawValue: mode) { self.liveMode = parsed }
        if let hold = table["clipboard_hold_seconds"]?.int { self.clipboardHoldSeconds = hold }

        if let rec = table["recording"]?.table {
            if let hotkey = rec["hotkey"]?.string { self.recording.hotkey = hotkey }
            if let sr = rec["sample_rate"]?.int { self.recording.sampleRate = sr }
            if let dev = rec["input_device"]?.string { self.recording.inputDevice = dev }
        }

        if let trans = table["transcription"]?.table {
            if let model = trans["model"]?.string {
                // Map Python MLX model names to WhisperKit CoreML names
                self.transcription.model = Self.mapModelName(model)
            }
        }
    }

    /// Map Python MLX model names to WhisperKit CoreML model names.
    private static func mapModelName(_ name: String) -> String {
        let mapping: [String: String] = [
            "mlx-community/whisper-large-v3-turbo": "openai_whisper-large-v3-v20240930_turbo_632MB",
            "mlx-community/whisper-large-v3": "openai_whisper-large-v3",
            "mlx-community/whisper-large-v2": "openai_whisper-large-v2",
            "mlx-community/whisper-small": "openai_whisper-small",
            "mlx-community/whisper-base": "openai_whisper-base",
            "mlx-community/whisper-tiny": "openai_whisper-tiny",
        ]
        return mapping[name] ?? name
    }

    /// Save a single string key-value pair to the user config file.
    func saveUserConfig(key: String, value: String) {
        setUserConfig(key: key, value: TOMLValue(stringLiteral: value))
    }

    /// Save a single boolean key-value pair to the user config file.
    func saveUserConfig(key: String, value: Bool) {
        setUserConfig(key: key, value: TOMLValue(booleanLiteral: value))
    }

    /// Save a single integer key-value pair to the user config file.
    func saveUserConfig(key: String, value: Int) {
        setUserConfig(key: key, value: TOMLValue(integerLiteral: value))
    }

    private func setUserConfig(key: String, value: any TOMLValueConvertible) {
        let configURL = Config.configDir.appendingPathComponent("config.toml")
        try? FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)

        var table: TOMLTable
        if let existing = try? String(contentsOf: configURL, encoding: .utf8),
           let parsed = try? TOMLTable(string: existing)
        {
            table = parsed
        } else {
            table = TOMLTable()
        }

        let parts = key.split(separator: ".").map(String.init)
        if parts.count == 2 {
            let section = table[parts[0]]?.table ?? TOMLTable()
            section[parts[1]] = value
            table[parts[0]] = section
        } else {
            table[key] = value
        }

        try? table.convert().write(to: configURL, atomically: true, encoding: .utf8)
    }
}
