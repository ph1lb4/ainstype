import CoreML
import Foundation
import os
import WhisperKit

/// Orchestrates the full pipeline: transcribe → dictionary → paste.
class Pipeline {
    private let config: Config
    fileprivate let whisperKitBox = OSAllocatedUnfairLock<WhisperKit?>(initialState: nil)
    let dictionary: DictionaryManager
    let history = TranscriptionHistory()

    /// Whether a model is available (bundled in app or previously downloaded).
    var hasCachedModel: Bool {
        bundledModelPath != nil || ModelState.load(expectedModel: config.transcription.model) != nil
    }

    /// Path to model bundled inside the .app bundle (Contents/Resources/Models/<model>).
    private var bundledModelPath: String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let path = (resourcePath as NSString).appendingPathComponent("Models/\(config.transcription.model)")
        for file in ModelState.requiredModelFiles {
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
                log("Downloading model: \(model) (~616MB, one-time)...")
                status("Downloading model…")

                let modelFolder = try await downloadModel(model, progress: progress)
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
                verbose: config.verbose,
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

    /// Fail the download if no progress is reported for this long (stalled connection).
    private static let downloadStallTimeout: TimeInterval = 90

    /// Download the model, racing it against a stall watchdog: if `progressCallback`
    /// goes silent for `downloadStallTimeout`, cancel and surface a retryable error
    /// instead of hanging on "Downloading model…" forever.
    private func downloadModel(_ model: String, progress: @escaping (Double) -> Void) async throws -> URL {
        let lastProgress = OSAllocatedUnfairLock<Date>(initialState: Date())
        let stallTimeout = Self.downloadStallTimeout

        return try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask { [weak self] in
                try await WhisperKit.download(
                    variant: model,
                    progressCallback: { downloadProgress in
                        lastProgress.withLock { $0 = Date() }
                        let pct = downloadProgress.fractionCompleted
                        if Int(pct * 100) % 10 == 0 {
                            self?.log("Download: \(Int(pct * 100))%")
                        }
                        progress(pct)
                    }
                )
            }
            group.addTask {
                while true {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    let idle = Date().timeIntervalSince(lastProgress.withLock { $0 })
                    if idle > stallTimeout { throw PipelineError.downloadStalled }
                }
            }

            guard let folder = try await group.next() else {
                throw PipelineError.downloadStalled
            }
            group.cancelAll()
            return folder
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
                verbose: config.verbose,
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

        // Privacy: never log transcribed content — only its size.
        log("Transcribed \(rawText.count) characters")

        // Dictionary replacements
        let text = dictionary.applyReplacements(rawText)
        history.add(text)

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

    /// Create a streaming session for live transcription, sharing this pipeline's
    /// loaded WhisperKit instance and dictionary.
    func makeLiveSession(config: Config) -> LiveSession {
        LiveSession(pipeline: self, config: config)
    }

    enum PipelineError: Error, LocalizedError {
        case modelNotReady
        case downloadStalled

        var errorDescription: String? {
            switch self {
            case .modelNotReady: "Whisper model not loaded yet — still initializing"
            case .downloadStalled: "Model download stalled — check your connection and try again"
            }
        }
    }
}

/// Stateful streaming transcription for live mode.
///
/// Mirrors WhisperKit's `AudioStreamTranscriber` confirmation strategy: the
/// growing audio buffer is re-transcribed periodically and split into
/// "confirmed" segments (stable, older audio) and an "unconfirmed" tail that may
/// still be revised. Only confirmed text is emitted while recording; the tail is
/// emitted by `finish()` on release.
final class LiveSession {
    private let pipeline: Pipeline
    private let config: Config
    private let sampleRate: Float = 16000
    /// Audio newer than this many seconds (from the end of the buffer) is left
    /// unconfirmed, since Whisper may still revise the most recent words.
    private let confirmationMargin: Float = 2.0

    private var lastConfirmedEnd: Float = 0
    private var hasEmitted = false
    /// Full text emitted so far this session (confirmed chunks + final tail),
    /// for recovery via the history window if pasting failed.
    private(set) var transcript = ""

    init(pipeline: Pipeline, config: Config) {
        self.pipeline = pipeline
        self.config = config
    }

    /// Transcribe the accumulated buffer and return newly-confirmed text
    /// (dictionary replacements applied), or nil if nothing was newly confirmed.
    func ingest(_ samples: [Float]) async throws -> String? {
        guard let wk = pipeline.whisperKitBox.withLock({ $0 }) else { return nil }

        // Confirm only audio older than the margin; need new confirmable audio first.
        let totalSeconds = Float(samples.count) / sampleRate
        let confirmBefore = totalSeconds - confirmationMargin
        guard confirmBefore > lastConfirmedEnd else { return nil }

        let segments = try await transcribe(samples, using: wk)
        let newlyConfirmed = segments.filter { $0.end > lastConfirmedEnd && $0.end <= confirmBefore }
        guard let last = newlyConfirmed.last else { return nil }
        lastConfirmedEnd = last.end

        return emit(newlyConfirmed.map { $0.text }.joined())
    }

    /// Final pass after recording stops: emit everything remaining after the last
    /// confirmed point (the unconfirmed tail).
    func finish(_ samples: [Float]) async throws -> String? {
        guard let wk = pipeline.whisperKitBox.withLock({ $0 }) else { return nil }
        let segments = try await transcribe(samples, using: wk)
        let remaining = segments.filter { $0.end > lastConfirmedEnd }
        guard !remaining.isEmpty else { return nil }
        return emit(remaining.map { $0.text }.joined())
    }

    private func transcribe(_ samples: [Float], using wk: WhisperKit) async throws -> [TranscriptionSegment] {
        var options = DecodingOptions(language: config.language, temperature: 0)
        // Decode clean word text (no <|...|> special/timestamp tokens in segment text).
        options.skipSpecialTokens = true
        // Only decode audio after the last confirmed point; segment timestamps
        // remain absolute from the start of `samples`.
        options.clipTimestamps = [lastConfirmedEnd]
        let results = try await wk.transcribe(audioArray: samples, decodeOptions: options)
        return results.flatMap { $0.segments }
    }

    /// Apply dictionary replacements and strip the leading space Whisper puts on
    /// the very first segment. Returns nil if the result is empty.
    private func emit(_ raw: String) -> String? {
        var text = raw
        if !hasEmitted {
            text = String(text.drop { $0 == " " })
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        hasEmitted = true
        let replaced = pipeline.dictionary.applyReplacements(text)
        transcript += replaced
        return replaced
    }
}
