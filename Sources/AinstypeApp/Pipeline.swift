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

            // WhisperKit 1.0 removed the separate prefill model (and its
            // prefillCompute option).
            let gpuOptions = ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndGPU,
                textDecoderCompute: .cpuAndGPU
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

        // Whisper hallucinates on silence — don't paste "Thank you." for a
        // stray hotkey tap.
        guard AudioGate.shouldTranscribe(audio, sampleRate: Float(config.recording.sampleRate)) else {
            log("Silence gate: no speech energy in \(audio.count) samples, skipping")
            return
        }

        let options = Pipeline.makeDecodingOptions(language: config.language)

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

    /// Base decoding options shared by batch and live transcription. When no
    /// language is configured, language detection must be requested explicitly:
    /// WhisperKit's prefill otherwise silently falls back to English.
    ///
    /// NOTE: dictionary-term biasing via `options.promptTokens` is deliberately
    /// NOT wired up. WhisperKit's decoder emits an empty transcription whenever
    /// promptTokens is set (any content, any language setting — reproduced with
    /// synthesized speech that decodes perfectly without a prompt). Verified
    /// broken in 0.17.0, 0.18.0 AND 1.0.0, so the initial-prompt feature is
    /// blocked until fixed upstream.
    static func makeDecodingOptions(language: String?) -> DecodingOptions {
        var options = DecodingOptions(language: language, temperature: 0)
        options.detectLanguage = (language == nil)
        return options
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
    private let sampleRate: Float
    private let assembler: LiveTextAssembler
    /// Audio newer than this many seconds (from the end of the buffer) is left
    /// unconfirmed, since Whisper may still revise the most recent words. Kept
    /// small: with word-level confirmation this is the main knob on how quickly
    /// spoken words surface, so it trades latency against last-word stability.
    private let confirmationMargin: Float = 1.0

    private var lastConfirmedEnd: Float = 0

    /// Full text emitted so far this session (confirmed chunks + final tail),
    /// for recovery via the history window if inserting failed.
    var transcript: String { assembler.transcript }

    init(pipeline: Pipeline, config: Config) {
        self.pipeline = pipeline
        self.config = config
        self.sampleRate = Float(config.recording.sampleRate)
        self.assembler = LiveTextAssembler(dictionary: pipeline.dictionary)
    }

    /// Transcribe the accumulated buffer and return newly-confirmed text
    /// (dictionary replacements applied), or nil if nothing was newly confirmed.
    func ingest(_ samples: [Float]) async throws -> String? {
        guard let wk = pipeline.whisperKitBox.withLock({ $0 }) else { return nil }
        guard AudioGate.shouldTranscribe(samples, sampleRate: sampleRate) else { return nil }

        // Confirm only audio older than the margin; need new confirmable audio first.
        let totalSeconds = Float(samples.count) / sampleRate
        let confirmBefore = totalSeconds - confirmationMargin
        guard confirmBefore > lastConfirmedEnd else { return nil }

        let units = confirmableUnits(try await transcribe(samples, using: wk))
        let newlyConfirmed = units.filter { $0.end > lastConfirmedEnd && $0.end <= confirmBefore }
        guard let last = newlyConfirmed.last else { return nil }
        lastConfirmedEnd = last.end

        return assembler.assemble(newlyConfirmed.map { $0.text }.joined())
    }

    /// Final pass after recording stops: emit everything remaining after the last
    /// confirmed point (the unconfirmed tail), plus any held-back words.
    func finish(_ samples: [Float]) async throws -> String? {
        guard let wk = pipeline.whisperKitBox.withLock({ $0 }),
              AudioGate.shouldTranscribe(samples, sampleRate: sampleRate)
        else {
            Logger.log("Live finish: skipping final decode (model unavailable or silence gate)")
            return assembler.flushPending()
        }
        let units = confirmableUnits(try await transcribe(samples, using: wk))
        let remaining = units.filter { $0.end > lastConfirmedEnd }
        return assembler.assemble(remaining.map { $0.text }.joined(), flush: true)
    }

    /// Recover text held back for a possible cross-chunk replacement when the
    /// final pass failed — held words must not be silently dropped.
    func flushPending() -> String? {
        assembler.flushPending()
    }

    /// The text units we can confirm independently, each tagged with the audio
    /// time it ends at. In `.sentence` mode (the default) each whole segment is
    /// one unit, so text lands in natural phrase-sized chunks. In `.word` mode
    /// each word is a unit (when the model returns word-level timestamps), so
    /// text surfaces mid-sentence without waiting for Whisper to close a segment
    /// at a pause — snappier, but it commits in rapid word bursts.
    private struct Unit { let text: String; let end: Float }
    private func confirmableUnits(_ segments: [TranscriptionSegment]) -> [Unit] {
        segments.flatMap { segment -> [Unit] in
            if config.liveMode == .word, let words = segment.words, !words.isEmpty {
                return words.map { Unit(text: $0.word, end: $0.end) }
            }
            return [Unit(text: segment.text, end: segment.end)]
        }
    }

    private func transcribe(_ samples: [Float], using wk: WhisperKit) async throws -> [TranscriptionSegment] {
        var options = Pipeline.makeDecodingOptions(language: config.language)
        // Decode clean word text (no <|...|> special/timestamp tokens in segment text).
        options.skipSpecialTokens = true
        // Word-level timestamps are only needed (and only worth their extra
        // compute) when confirming word-by-word.
        options.wordTimestamps = config.liveMode == .word
        // Only decode audio after the last confirmed point; segment and word
        // timestamps remain absolute from the start of `samples`.
        options.clipTimestamps = [lastConfirmedEnd]
        let results = try await wk.transcribe(audioArray: samples, decodeOptions: options)
        return results.flatMap { $0.segments }
    }

}

/// Turns newly-confirmed raw Whisper text into the exact string to type,
/// independent of audio state so it can be unit tested. Handles: dropping the
/// first chunk's leading space, dropping a decode-boundary duplicate word,
/// holding back trailing words that may start a multi-word replacement phrase,
/// applying dictionary replacements, and accumulating the session transcript.
final class LiveTextAssembler {
    private static let openingOrJoiningPunctuation: Set<Character> = [
        "(", "[", "{", "\u{2018}", "\u{201C}", "-", "\u{2013}", "\u{2014}", "/",
    ]
    private static let attachingPunctuation: Set<Character> = [
        ".", ",", "!", "?", ";", ":", "%", "\u{2026}",
        ")", "]", "}", "'", "\u{2019}", "-", "\u{2013}", "\u{2014}",
    ]

    private let dictionary: DictionaryManager
    private var hasEmitted = false
    /// The last confirmed word (normalized), used to drop an accidental repeat
    /// when a decode boundary re-transcribes the word it was clipped on (the
    /// `correctlycorrectly` / `whichwhich` artifact).
    private var lastWord = ""
    /// Confirmed text withheld from emission because it could be the start of a
    /// multi-word replacement phrase; prepended to the next chunk.
    private var pendingHold = ""
    /// Full text emitted so far (confirmed chunks + final tail), for recovery
    /// via the history window if inserting failed.
    private(set) var transcript = ""

    init(dictionary: DictionaryManager) {
        self.dictionary = dictionary
    }

    /// Prepare a newly-confirmed chunk for insertion. Whisper usually prefixes
    /// words/segments with a leading space, but a decode that starts at
    /// `clipTimestamps` is also allowed to return text without one. Normalize the
    /// boundary explicitly so independently decoded chunks can never merge. The
    /// very first output's leading space is dropped so text doesn't start with a
    /// space. Returns nil if nothing is left to emit.
    /// With `flush`, held-back text is emitted too — used for the final tail
    /// when recording stops.
    func assemble(_ raw: String, flush: Bool = false) -> String? {
        var text = raw
        if !hasEmitted && pendingHold.isEmpty {
            text = String(text.drop { $0 == " " })
        } else {
            text = addMissingBoundarySpace(to: text)
        }
        text = dropDuplicateLeadingWord(text)

        let hasNewText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Nothing new and nothing to flush: leave any held text in place.
        if !hasNewText && !flush { return nil }

        if hasNewText, let last = text.split(separator: " ").last {
            lastWord = Self.normalizeWord(String(last))
        }

        var out = pendingHold + (hasNewText ? text : "")
        pendingHold = ""
        if !flush {
            let (emit, hold) = dictionary.holdbackSplit(out)
            pendingHold = hold
            out = emit
        }
        guard !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        hasEmitted = true
        let replaced = dictionary.applyReplacements(out)
        transcript += replaced
        return replaced
    }

    /// Emit whatever is held back without new input — used when a session ends
    /// on an error path so held words are not silently dropped.
    func flushPending() -> String? {
        assemble("", flush: true)
    }

    /// Add the separator that Whisper sometimes omits at the start of a clipped
    /// decode. Closing punctuation and contraction suffixes intentionally remain
    /// attached to the preceding word.
    private func addMissingBoundarySpace(to text: String) -> String {
        guard let first = text.first, !first.isWhitespace else { return text }

        let previous = pendingHold.last ?? transcript.last
        guard let previous, !previous.isWhitespace else { return text }

        guard !Self.openingOrJoiningPunctuation.contains(previous),
              !Self.attachingPunctuation.contains(first)
        else { return text }
        return " " + text
    }

    /// If `text`'s first word repeats `lastWord`, remove it (keeping the space
    /// that precedes the following word so separation is preserved).
    private func dropDuplicateLeadingWord(_ text: String) -> String {
        guard !lastWord.isEmpty else { return text }
        let afterSpaces = text.drop { $0 == " " }
        let firstWord = afterSpaces.prefix { $0 != " " }
        guard Self.normalizeWord(String(firstWord)) == lastWord else { return text }
        return String(afterSpaces.dropFirst(firstWord.count))
    }

    /// Lowercased, with surrounding punctuation stripped, for comparing words
    /// regardless of trailing periods/commas Whisper may attach.
    private static func normalizeWord(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).lowercased()
    }
}
