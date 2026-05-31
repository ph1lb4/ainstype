import CoreML
import Foundation
import os
import WhisperKit

/// Orchestrates the full pipeline: transcribe → dictionary → paste.
class Pipeline {
    private let config: Config
    private let whisperKitBox = OSAllocatedUnfairLock<WhisperKit?>(initialState: nil)
    let dictionary: DictionaryManager

    /// Whether a model is available (bundled in app or previously downloaded).
    var hasCachedModel: Bool {
        bundledModelPath != nil || ModelState.load(expectedModel: config.transcription.model) != nil
    }

    /// Path to model bundled inside the .app bundle (Contents/Resources/Models/<model>).
    private var bundledModelPath: String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let path = (resourcePath as NSString).appendingPathComponent("Models/\(config.transcription.model)")
        let required = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]
        for file in required {
            if !FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(file)) {
                return nil
            }
        }
        return path
    }

    init(config: Config) {
        self.config = config
        self.dictionary = DictionaryManager()
    }

    /// Two-phase model init.
    ///   Phase 1: fast GPU-only load (no ANE compilation). User can record as soon as this finishes.
    ///   Phase 2: background load with ANE compute units; swaps in for faster inference once ready.
    func warmUp(
        progress: @escaping (Double) -> Void,
        status: @escaping (String) -> Void
    ) async {
        let model = config.transcription.model

        do {
            let modelPath: String
            let cached = ModelState.load(expectedModel: model)

            // Resolve model path: bundled > cached > download
            if let bundled = bundledModelPath {
                modelPath = bundled
                log("Using bundled model at \(modelPath)")
            } else if let cached {
                modelPath = cached.modelPath
                log("Using cached model at \(modelPath)")
            } else {
                // No bundled model and no cache — download
                log("Downloading model: \(model) (~950MB, one-time)...")
                status("Downloading model…")

                let modelFolder = try await WhisperKit.download(
                    variant: model,
                    progressCallback: { [weak self] downloadProgress in
                        let pct = downloadProgress.fractionCompleted
                        if Int(pct * 100) % 10 == 0 {
                            self?.log("Download: \(Int(pct * 100))%")
                        }
                        progress(pct)
                    }
                )
                modelPath = modelFolder.path
                ModelState.save(modelPath: modelPath, model: model, aneSpecialized: false)
                log("Model downloaded and cached")
            }

            // Phase 1: fast GPU-only load. Skips ANE specialization (which can take minutes
            // on first launch and a few seconds on warm launches).
            status("Loading model…")
            let phase1Start = CFAbsoluteTimeGetCurrent()
            log("Phase 1: GPU-only model load...")

            let gpuOptions = ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndGPU,
                textDecoderCompute: .cpuAndGPU,
                prefillCompute: .cpuOnly
            )

            // Split prewarm and loadModels so the caller's prewarmHook can run
            // concurrently with the final load step (audio engine warmup, etc.).
            let gpuWK = try await WhisperKit(
                modelFolder: modelPath,
                computeOptions: gpuOptions,
                verbose: true,
                prewarm: true,
                load: false,
                download: false
            )

            try await gpuWK.loadModels()

            whisperKitBox.withLock { $0 = gpuWK }

            let phase1Elapsed = CFAbsoluteTimeGetCurrent() - phase1Start
            log(String(format: "Phase 1 ready in %.1fs — GPU inference active", phase1Elapsed))
            status("ready")

            // Phase 2: upgrade to ANE in the background. First-time ANE specialization is
            // expensive but cached by CoreML in ~/Library/Caches/com.apple.e5rt.e5bundlecache;
            // subsequent launches just reuse the cached compilation.
            let needsSpecialization = cached?.aneSpecialized != true
            Task.detached(priority: .utility) { [weak self] in
                await self?.upgradeToANE(modelPath: modelPath, isFirstTime: needsSpecialization)
            }
        } catch {
            log("ERROR: Failed to initialize WhisperKit: \(error)")
            status("error")
        }
    }

    /// Phase 2: load a second WhisperKit instance with ANE compute units and swap it in.
    /// On first run this performs CoreML ANE specialization (slow); afterwards it's a quick
    /// reload from the e5rt cache.
    private func upgradeToANE(modelPath: String, isFirstTime: Bool) async {
        let model = config.transcription.model
        if isFirstTime {
            log("Phase 2: ANE specialization in background (first-time, may take several minutes)...")
        } else {
            log("Phase 2: ANE-specialized model loading in background...")
        }
        let phase2Start = CFAbsoluteTimeGetCurrent()
        do {
            let aneOptions = ModelComputeOptions() // defaults: ANE for encoder + decoder on macOS 14+
            let aneWK = try await WhisperKit(
                modelFolder: modelPath,
                computeOptions: aneOptions,
                verbose: true,
                prewarm: false,
                load: true,
                download: false
            )
            whisperKitBox.withLock { $0 = aneWK }
            ModelState.save(modelPath: modelPath, model: model, aneSpecialized: true)
            let elapsed = CFAbsoluteTimeGetCurrent() - phase2Start
            log(String(format: "Phase 2 complete in %.1fs — ANE inference active", elapsed))
        } catch {
            log("Phase 2 ANE upgrade failed (staying on GPU): \(error)")
        }
    }

    /// Log to both file and stdout.
    func log(_ message: String) {
        Logger.log(message)
        print("[ainstype] \(message)")
        fflush(stdout)
    }

    /// Run the full pipeline on recorded audio.
    func processAudio(_ audio: [Float], config: Config) async throws {
        guard let wk = whisperKitBox.withLock({ $0 }) else {
            throw PipelineError.modelNotReady
        }

        let options = DecodingOptions(
            language: config.language,
            temperature: 0
        )

        log("Transcribing \(audio.count) samples...")
        let results = try await wk.transcribe(audioArray: audio, decodeOptions: options)
        let rawText = results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawText.isEmpty else {
            log("No speech detected")
            return
        }

        log("Transcription: \(rawText.prefix(200))")

        // Dictionary replacements
        let text = dictionary.applyReplacements(rawText)

        // Paste to focused app
        log("Pasting result...")
        if config.autoPaste {
            let success = Clipboard.pasteToFocusedApp(text)
            if !success {
                log("Paste failed — check Accessibility permission")
                Clipboard.copy(text)
            }
        } else {
            Clipboard.copy(text)
        }
    }

    enum PipelineError: Error, LocalizedError {
        case modelNotReady

        var errorDescription: String? {
            switch self {
            case .modelNotReady: "Whisper model not loaded yet — still initializing"
            }
        }
    }
}
