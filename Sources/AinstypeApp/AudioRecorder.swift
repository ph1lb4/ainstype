import Accelerate
import AVFoundation

/// Energy gate deciding whether captured audio is worth sending to Whisper.
/// Whisper hallucinates text ("Thank you.", "you", …) on silence and near-silence,
/// so buffers with no plausible speech energy are dropped before transcription.
enum AudioGate {
    /// Buffers shorter than this can't contain a word — treat as accidental taps.
    static let minimumDuration: Float = 0.3
    /// Peak amplitude below this (~-42 dBFS) is considered silence. Chosen well
    /// under quiet speech (peaks ≳ 0.02) but above a muted/idle mic noise floor.
    static let silencePeak: Float = 0.0075

    static func shouldTranscribe(_ samples: [Float], sampleRate: Float) -> Bool {
        guard Float(samples.count) >= minimumDuration * sampleRate else { return false }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        return peak >= silencePeak
    }
}

/// Converts microphone tap buffers to the 16kHz mono Float32 format Whisper
/// expects. Wraps AVAudioConverter for testability.
final class TapConverter {
    private let converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private let ratio: Double

    /// Fails (nil) if the formats differ and no converter can be built — the
    /// caller should abort recording rather than capture wrong-rate audio.
    init?(from inputFormat: AVAudioFormat, to targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
        self.ratio = targetFormat.sampleRate / inputFormat.sampleRate
        if inputFormat.sampleRate != targetFormat.sampleRate || inputFormat.channelCount != targetFormat.channelCount {
            guard let c = AVAudioConverter(from: inputFormat, to: targetFormat) else { return nil }
            self.converter = c
        } else {
            self.converter = nil
        }
    }

    /// Convert one tap buffer; returns nil on conversion failure.
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let outputBuffer: AVAudioPCMBuffer
        if let converter {
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputFrameCount
            ) else { return nil }

            // The converter may call the input block several times per convert()
            // to fill the output buffer (resampler priming). Hand the buffer over
            // exactly once — returning it again would duplicate captured audio.
            var consumed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            if error != nil { return nil }
            outputBuffer = converted
        } else {
            outputBuffer = buffer
        }

        guard let channelData = outputBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(outputBuffer.frameLength)
        ))
    }
}

/// Records audio from the default microphone using AVAudioEngine.
/// Output: 16kHz mono Float32 array (what Whisper expects).
class AudioRecorder {
    let sampleRate: Double
    private var engine: AVAudioEngine?
    private var frames: [[Float]] = []
    private let lock = NSLock()
    private var isRecording = false

    init(sampleRate: Int = 16000) {
        self.sampleRate = Double(sampleRate)
    }

    /// Briefly spin up CoreAudio to warm its device/format caches so the first
    /// real `start()` doesn't pay the cold-start cost, then tear everything down
    /// again. Holding the engine alive after this would keep the input AU open
    /// and cause other apps to duck as if a call were active — so we throw the
    /// engine away. CoreAudio's internal caches survive for long enough that
    /// the next `start()` is still fast.
    func prewarm() {
        let warm = AVAudioEngine()
        _ = warm.inputNode.outputFormat(forBus: 0)
        warm.stop()
    }

    /// Request microphone permission. Calls completion on main thread.
    static func requestPermission(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// Begin recording from the default microphone.
    ///
    /// The engine is constructed fresh on each start and fully released on stop —
    /// merely holding an `AVAudioEngine` whose `inputNode` has been touched keeps
    /// the CoreAudio input unit alive, which other apps interpret as an active
    /// call and respond to by ducking their playback.
    func start() throws {
        lock.lock()
        if isRecording { lock.unlock(); return }
        frames = []
        isRecording = true
        lock.unlock()

        let engine = AVAudioEngine()
        self.engine = engine
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // We need 16kHz mono for Whisper
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let tapConverter = TapConverter(from: inputFormat, to: targetFormat) else {
            // Roll back so a format failure doesn't leave us wedged, and abort
            // rather than capture wrong-rate audio Whisper can't use.
            self.engine = nil
            lock.lock()
            isRecording = false
            lock.unlock()
            throw RecorderError.formatError
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let data = tapConverter.convert(buffer) else { return }
            self.lock.lock()
            self.frames.append(data)
            self.lock.unlock()
        }

        do {
            try engine.start()
        } catch {
            // Roll back state so a failed start doesn't leave us wedged.
            self.engine = nil
            lock.lock()
            isRecording = false
            lock.unlock()
            throw error
        }
        Logger.log("AudioRecorder started")
    }

    /// Snapshot of all audio captured so far, without stopping recording or
    /// clearing the buffer. Used by live mode to transcribe the growing buffer
    /// periodically; sample timestamps stay absolute from the start of recording.
    func currentSamples() -> [Float] {
        lock.lock()
        let snapshot = frames
        lock.unlock()
        return snapshot.flatMap { $0 }
    }

    /// Stop recording and return concatenated audio samples.
    func stop() -> [Float] {
        lock.lock()
        if !isRecording { lock.unlock(); return [] }
        isRecording = false
        lock.unlock()

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        // Drop the engine so the CoreAudio input unit is released and other
        // apps stop treating the system as if a call is active.
        engine = nil

        lock.lock()
        let allFrames = frames
        frames = []
        lock.unlock()

        let result = allFrames.flatMap { $0 }
        Logger.log("AudioRecorder stopped, \(result.count) samples")
        return result
    }

    enum RecorderError: Error {
        case formatError
    }
}
