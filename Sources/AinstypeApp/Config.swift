import Foundation
import TOMLKit

struct RecordingConfig {
    var hotkey: String = "cmd_r"
    var sampleRate: Int = 16000
}

struct TranscriptionConfig {
    var model: String = "openai_whisper-large-v3-v20240930_turbo_632MB"
}

struct Config {
    var language: String? = nil
    var autoPaste: Bool = true
    var verbose: Bool = false
    /// When true, paste confirmed text incrementally while recording (live mode)
    /// instead of pasting everything once on hotkey release. On by default.
    var liveTranscription: Bool = true
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
    private mutating func validate() {
        if !HotkeyMonitor.supportedKeys.contains(recording.hotkey) {
            Logger.error("Invalid hotkey '\(recording.hotkey)' in config — falling back to 'cmd_r'. Supported: \(HotkeyMonitor.supportedKeys.joined(separator: ", "))")
            recording.hotkey = "cmd_r"
        }
        if recording.sampleRate <= 0 {
            Logger.error("Invalid sample_rate \(recording.sampleRate) in config — falling back to 16000")
            recording.sampleRate = 16000
        }
    }

    mutating func applyTOML(_ tomlString: String) {
        guard let table = try? TOMLTable(string: tomlString) else { return }

        if let language = table["language"]?.string { self.language = language }
        if let autoPaste = table["auto_paste"]?.bool { self.autoPaste = autoPaste }
        if let verbose = table["verbose"]?.bool { self.verbose = verbose }
        if let live = table["live_transcription"]?.bool { self.liveTranscription = live }

        if let rec = table["recording"]?.table {
            if let hotkey = rec["hotkey"]?.string { self.recording.hotkey = hotkey }
            if let sr = rec["sample_rate"]?.int { self.recording.sampleRate = sr }
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
