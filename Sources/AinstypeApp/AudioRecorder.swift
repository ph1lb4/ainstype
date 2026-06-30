import AVFoundation

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
        ) else {
            throw RecorderError.formatError
        }

        // Install converter if sample rates differ
        let converter: AVAudioConverter?
        if inputFormat.sampleRate != sampleRate || inputFormat.channelCount != 1 {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        } else {
            converter = nil
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let outputBuffer: AVAudioPCMBuffer
            if let converter {
                let ratio = self.sampleRate / inputFormat.sampleRate
                let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
                guard let converted = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: outputFrameCount
                ) else { return }

                var error: NSError?
                converter.convert(to: converted, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                if error != nil { return }
                outputBuffer = converted
            } else {
                outputBuffer = buffer
            }

            guard let channelData = outputBuffer.floatChannelData else { return }
            let data = Array(UnsafeBufferPointer(
                start: channelData[0],
                count: Int(outputBuffer.frameLength)
            ))

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
