import Foundation

/// Persists the downloaded model path so subsequent launches skip network checks.
/// Stored at ~/.config/ainstype/model_state.json
struct ModelState: Codable {
    let modelPath: String
    let model: String
    let downloadedAt: String
    let aneSpecialized: Bool

    private static let stateURL = Config.configDir.appendingPathComponent("model_state.json")

    // Backward-compatible decoding (old JSON files won't have aneSpecialized)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelPath = try container.decode(String.self, forKey: .modelPath)
        model = try container.decode(String.self, forKey: .model)
        downloadedAt = try container.decode(String.self, forKey: .downloadedAt)
        aneSpecialized = try container.decodeIfPresent(Bool.self, forKey: .aneSpecialized) ?? false
    }

    init(modelPath: String, model: String, downloadedAt: String, aneSpecialized: Bool) {
        self.modelPath = modelPath
        self.model = model
        self.downloadedAt = downloadedAt
        self.aneSpecialized = aneSpecialized
    }

    /// Load cached model state. Returns nil if missing, corrupt, or model name changed.
    static func load(expectedModel: String) -> ModelState? {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(ModelState.self, from: data)
        else { return nil }

        // Invalidate if model name changed in config
        guard state.model == expectedModel else {
            print("[ainstype] Model changed (\(state.model) → \(expectedModel)), will re-download")
            return nil
        }

        // Validate that model files still exist on disk
        let modelURL = URL(fileURLWithPath: state.modelPath)
        let requiredFiles = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]
        for file in requiredFiles {
            if !FileManager.default.fileExists(atPath: modelURL.appendingPathComponent(file).path) {
                print("[ainstype] Model file missing: \(file), will re-download")
                return nil
            }
        }

        return state
    }

    /// Save model state after successful download or ANE specialization.
    static func save(modelPath: String, model: String, aneSpecialized: Bool) {
        let state = ModelState(
            modelPath: modelPath,
            model: model,
            downloadedAt: ISO8601DateFormatter().string(from: Date()),
            aneSpecialized: aneSpecialized
        )
        try? FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL)
        }
    }

    /// Delete cached state (forces re-download on next launch).
    static func clear() {
        try? FileManager.default.removeItem(at: stateURL)
    }
}
