import Accelerate
import AudioToolbox
import AVFoundation
import CoreAudio

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

/// A microphone the user can capture from, surfaced in the Settings picker.
struct InputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBuiltIn: Bool
}

/// Which microphone `AudioRecorder` should capture from.
///
/// Capturing from a Bluetooth headset's own mic forces the whole device into
/// the low-quality hands-free/call profile (HFP) — music suddenly plays loud
/// and tinny. Capturing from the built-in mic instead leaves the headset in
/// full-quality A2DP playback, so music is untouched while recording — which is
/// why the Settings picker offers `.builtIn` as a fix for that case.
enum InputDeviceSelection: Equatable {
    /// Whatever CoreAudio hands us (the system's default input device).
    case systemDefault
    /// The Mac's built-in microphone, resolved at record time.
    case builtIn
    /// A specific device, matched by its stable CoreAudio UID.
    case uid(String)

    /// Round-trips through the string stored in `config.toml`.
    init(configValue: String) {
        switch configValue {
        case "", "default": self = .systemDefault
        case "builtin": self = .builtIn
        default: self = .uid(configValue)
        }
    }

    var configValue: String {
        switch self {
        case .systemDefault: return "default"
        case .builtIn: return "builtin"
        case .uid(let uid): return uid
        }
    }
}

/// CoreAudio device enumeration used by the recorder and the Settings picker.
enum AudioDevices {
    /// All devices that expose input channels, in CoreAudio's device order.
    static func inputDevices() -> [InputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasInputChannels(id), let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = stringProperty(id, kAudioObjectPropertyName) ?? uid
            let isBuiltIn = transportType(id) == kAudioDeviceTransportTypeBuiltIn
            return InputDevice(id: id, uid: uid, name: name, isBuiltIn: isBuiltIn)
        }
    }

    /// Resolve a selection to a concrete device id. Returns nil for
    /// `.systemDefault`, or when a requested device is no longer connected —
    /// the caller should then leave the engine on the system default input.
    static func resolve(_ selection: InputDeviceSelection) -> AudioDeviceID? {
        switch selection {
        case .systemDefault: return nil
        case .builtIn: return inputDevices().first(where: { $0.isBuiltIn })?.id
        case .uid(let uid): return inputDevices().first(where: { $0.uid == uid })?.id
        }
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, buffer) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, &value) == noErr else { return 0 }
        return value
    }

    // MARK: - Diagnostics

    /// Human-readable summary of the current default output device: name,
    /// transport, sample rate (A2DP ≈ 44.1/48kHz; call profile drops far lower)
    /// and volume (0–1). Used to trace Bluetooth profile/volume changes in logs.
    static func defaultOutputState() -> String {
        guard let id = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else { return "none" }
        let name = stringProperty(id, kAudioObjectPropertyName) ?? "?"
        let transport = fourCC(transportType(id))
        let rate = deviceRate(id)
        let vol = deviceVolume(id)
        return "[\(name) \(transport) \(Int(rate))Hz vol=\(vol.map { String(format: "%.2f", $0) } ?? "n/a")]"
    }

    static func defaultInputName() -> String {
        guard let id = defaultDevice(kAudioHardwarePropertyDefaultInputDevice) else { return "none" }
        return "\(stringProperty(id, kAudioObjectPropertyName) ?? "?") (\(fourCC(transportType(id))))"
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return (status == noErr && id != 0) ? id : nil
    }

    private static func deviceRate(_ id: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Double>.size)
        var value: Double = 0
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func deviceVolume(_ id: AudioDeviceID) -> Float? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var size = UInt32(MemoryLayout<Float>.size)
        var value: Float = 0
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(value)"
    }
}

/// Records audio from the default microphone using AVAudioEngine.
/// Output: 16kHz mono Float32 array (what Whisper expects).
class AudioRecorder {
    let sampleRate: Double
    /// Which microphone to capture from. Read on each `start()`, so changing it
    /// from Settings takes effect on the next recording. `StatusMenuController`
    /// sets this from config at launch (system default unless the user picks a
    /// specific device — e.g. "builtin" to keep Bluetooth headphones out of
    /// call mode).
    var inputDevice: InputDeviceSelection = .systemDefault
    private var engine: AVAudioEngine?
    private var frames: [[Float]] = []
    private let lock = NSLock()
    private var isRecording = false
    /// Holds Bluetooth output at its music volume while recording, so opening the
    /// mic doesn't make macOS swap in the headset's separate "call" volume.

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
        Logger.log("prewarm: output \(AudioDevices.defaultOutputState()), default-input \(AudioDevices.defaultInputName())")
        let warm = AVAudioEngine()
        // Pin to the configured device before touching the input so we don't open
        // the default (possibly Bluetooth) mic here and trip a profile switch.
        applyInputDevice(to: warm.inputNode)
        _ = warm.inputNode.outputFormat(forBus: 0)
        warm.stop()
        Logger.log("prewarm done: output \(AudioDevices.defaultOutputState())")
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

        Logger.log("start: default-input \(AudioDevices.defaultInputName()), output \(AudioDevices.defaultOutputState())")
        let engine = AVAudioEngine()
        self.engine = engine
        let inputNode = engine.inputNode
        // Pin the capture device before reading the input format — the format
        // (sample rate, channels) depends on which device is selected.
        applyInputDevice(to: inputNode)
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
        Logger.log("AudioRecorder started; output \(AudioDevices.defaultOutputState())")
        // Sample the output device shortly after — macOS applies any call-mode
        // switch asynchronously (~0.4s after the input opens).
        for delay in [0.5, 1.2] {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                guard self?.isRecording == true else { return }
                Logger.log("  +\(delay)s output \(AudioDevices.defaultOutputState())")
            }
        }
    }

    /// Point the engine's input at the configured device. A no-op for
    /// `.systemDefault`; for a specific/built-in device that can't be resolved
    /// (unplugged, no built-in mic) we log and fall back to the system default
    /// rather than fail the recording.
    private func applyInputDevice(to inputNode: AVAudioInputNode) {
        guard inputDevice != .systemDefault else { return }
        guard let deviceID = AudioDevices.resolve(inputDevice) else {
            Logger.error("Input device '\(inputDevice.configValue)' not found — using system default")
            return
        }
        guard let audioUnit = inputNode.audioUnit else { return }
        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            Logger.error("Failed to set input device (status \(status)) — using system default")
        }
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
        Logger.log("stop: output \(AudioDevices.defaultOutputState())")

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
