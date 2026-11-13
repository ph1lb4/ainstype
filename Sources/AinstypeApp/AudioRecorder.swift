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

    static func defaultInputID() -> AudioDeviceID? {
        defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    static func name(of id: AudioDeviceID) -> String {
        "\(stringProperty(id, kAudioObjectPropertyName) ?? "?") (\(fourCC(transportType(id))))"
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

/// Records audio from one input device with an input-only CoreAudio HAL unit.
/// Output: 16kHz mono Float32 array (what Whisper expects).
///
/// `AVAudioEngine` is not used: touching its `inputNode` opens the system default
/// input before another device can be selected, and its output side stays bound to
/// the default output. With Bluetooth headphones that puts the headset into the
/// call profile even when the built-in mic is selected. This unit opens only the
/// selected input device and never touches the output device.
class AudioRecorder {
    let sampleRate: Double
    /// Which microphone to capture from. Read on each `start()`, so changing it
    /// from Settings takes effect on the next recording.
    var inputDevice: InputDeviceSelection = .systemDefault
    private var capture: InputCapture?
    private var frames: [[Float]] = []
    private let lock = NSLock()
    private var isRecording = false

    init(sampleRate: Int = 16000) {
        self.sampleRate = Double(sampleRate)
    }

    /// Load the HAL audio component so the first `start()` is fast. Opens no device.
    func prewarm() {
        Logger.log("prewarm: output \(AudioDevices.defaultOutputState()), default-input \(AudioDevices.defaultInputName())")
        _ = AudioDevices.inputDevices()
        if let unit = InputCapture.makeUnit() {
            AudioComponentInstanceDispose(unit)
        }
        Logger.log("prewarm done: output \(AudioDevices.defaultOutputState())")
    }

    /// Request microphone permission. Calls completion on main thread.
    static func requestPermission(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func start() throws {
        lock.lock()
        if isRecording { lock.unlock(); return }
        frames = []
        isRecording = true
        lock.unlock()

        let deviceID: AudioDeviceID
        if inputDevice != .systemDefault, let resolved = AudioDevices.resolve(inputDevice) {
            deviceID = resolved
        } else if let fallback = AudioDevices.defaultInputID() {
            if inputDevice != .systemDefault {
                Logger.error("Input device '\(inputDevice.configValue)' not found — using system default")
            }
            deviceID = fallback
        } else {
            rollBack()
            throw RecorderError.noInputDevice
        }

        Logger.log("start: device \(AudioDevices.name(of: deviceID)), output \(AudioDevices.defaultOutputState())")
        do {
            capture = try InputCapture(deviceID: deviceID, targetSampleRate: sampleRate) { [weak self] samples in
                guard let self else { return }
                self.lock.lock()
                self.frames.append(samples)
                self.lock.unlock()
            }
        } catch {
            rollBack()
            throw error
        }
        Logger.log("AudioRecorder started; output \(AudioDevices.defaultOutputState())")
    }

    private func rollBack() {
        lock.lock()
        isRecording = false
        lock.unlock()
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

    /// Stop recording, release the device and return concatenated audio samples.
    func stop() -> [Float] {
        lock.lock()
        if !isRecording { lock.unlock(); return [] }
        isRecording = false
        lock.unlock()

        capture?.stop()
        capture = nil
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
        case noInputDevice
        case coreAudio(String, OSStatus)
    }
}

/// Fixed-size sample buffer between the audio thread (writes) and a normal
/// queue (reads). Allocates only in `init`; the lock is held only for copies.
final class SampleRing {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var readIndex = 0
    private var count = 0
    private var lock = os_unfair_lock()
    private var dropped = 0

    var droppedSamples: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return dropped
    }

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
    }

    deinit { storage.deallocate() }

    /// Called on the audio thread. Samples that do not fit are dropped and counted.
    func write(_ source: UnsafePointer<Float>, count frames: Int) {
        os_unfair_lock_lock(&lock)
        let accepted = min(frames, capacity - count)
        var writeIndex = (readIndex + count) % capacity
        var copied = 0
        while copied < accepted {
            let chunk = min(accepted - copied, capacity - writeIndex)
            (storage + writeIndex).update(from: source + copied, count: chunk)
            copied += chunk
            writeIndex = (writeIndex + chunk) % capacity
        }
        count += accepted
        dropped += frames - accepted
        os_unfair_lock_unlock(&lock)
    }

    /// Moves all buffered samples into `destination` and returns how many were moved.
    func read(into destination: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        os_unfair_lock_lock(&lock)
        let taken = min(count, maxCount)
        var copied = 0
        while copied < taken {
            let chunk = min(taken - copied, capacity - readIndex)
            (destination + copied).update(from: storage + readIndex, count: chunk)
            copied += chunk
            readIndex = (readIndex + chunk) % capacity
        }
        count -= taken
        os_unfair_lock_unlock(&lock)
        return taken
    }
}

/// One running input-only HAL unit bound to a single device. Starts in `init`,
/// releases the device in `stop()`. The audio thread only copies samples into a
/// ring buffer; resampling runs on a normal queue.
final class InputCapture {
    private var unit: AudioUnit?
    private let renderBuffer: AVAudioPCMBuffer
    private let drainBuffer: AVAudioPCMBuffer
    private let ring: SampleRing
    private let converter: TapConverter
    private let onSamples: ([Float]) -> Void
    private let queue = DispatchQueue(label: "com.ainstype.input-capture")
    private var drainTimer: DispatchSourceTimer?
    private var reportedDrops = 0
    private static let inputBus: AudioUnitElement = 1
    private static let outputBus: AudioUnitElement = 0
    private static let maxFrames: AVAudioFrameCount = 8192
    private static let ringSeconds: Double = 2
    private static let drainInterval: DispatchTimeInterval = .milliseconds(20)

    static func makeUnit() -> AudioUnit? {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr else { return nil }
        return unit
    }

    init(deviceID: AudioDeviceID, targetSampleRate: Double, onSamples: @escaping ([Float]) -> Void) throws {
        self.onSamples = onSamples
        guard let unit = InputCapture.makeUnit() else {
            throw AudioRecorder.RecorderError.coreAudio("create unit", -1)
        }

        func check(_ status: OSStatus, _ step: String) throws {
            if status != noErr {
                AudioComponentInstanceDispose(unit)
                throw AudioRecorder.RecorderError.coreAudio(step, status)
            }
        }

        // The output side must be off before the device is set, or the unit binds
        // to the default output device as well.
        var on: UInt32 = 1
        var off: UInt32 = 0
        let flagSize = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, InputCapture.inputBus, &on, flagSize), "enable input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, InputCapture.outputBus, &off, flagSize), "disable output")

        var device = deviceID
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)), "set device")

        var deviceFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, InputCapture.inputBus, &deviceFormat, &formatSize), "read device format")

        // The HAL unit converts sample format and channel count but not sample
        // rate, so capture mono Float32 at the device rate and resample after.
        let ringCapacity = Int(deviceFormat.mSampleRate * InputCapture.ringSeconds)
        guard deviceFormat.mSampleRate > 0,
              let captureFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: deviceFormat.mSampleRate, channels: 1, interleaved: false),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false),
              let converter = TapConverter(from: captureFormat, to: targetFormat),
              let renderBuffer = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: InputCapture.maxFrames),
              let drainBuffer = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: AVAudioFrameCount(ringCapacity)) else {
            AudioComponentInstanceDispose(unit)
            throw AudioRecorder.RecorderError.formatError
        }
        self.converter = converter
        self.renderBuffer = renderBuffer
        self.drainBuffer = drainBuffer
        self.ring = SampleRing(capacity: ringCapacity)

        var clientFormat = captureFormat.streamDescription.pointee
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, InputCapture.inputBus, &clientFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set client format")

        var maxFrames = UInt32(InputCapture.maxFrames)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, flagSize), "set max frames")

        var callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timeStamp, bus, frameCount, _ in
                let capture = Unmanaged<InputCapture>.fromOpaque(refCon).takeUnretainedValue()
                return capture.render(flags: flags, timeStamp: timeStamp, bus: bus, frameCount: frameCount)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set input callback")

        try check(AudioUnitInitialize(unit), "initialize")

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + InputCapture.drainInterval, repeating: InputCapture.drainInterval)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        drainTimer = timer

        self.unit = unit
        let startStatus = AudioOutputUnitStart(unit)
        if startStatus != noErr {
            self.unit = nil
            timer.cancel()
            drainTimer = nil
            AudioUnitUninitialize(unit)
            try check(startStatus, "start")
        }
    }

    /// Runs on the audio thread: no allocation, no conversion.
    private func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frameCount: UInt32
    ) -> OSStatus {
        guard let unit, frameCount <= renderBuffer.frameCapacity,
              let channel = renderBuffer.floatChannelData?[0] else { return noErr }
        renderBuffer.frameLength = frameCount
        let list = renderBuffer.mutableAudioBufferList
        list.pointee.mBuffers.mDataByteSize = frameCount * UInt32(MemoryLayout<Float>.size)
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frameCount, list)
        if status == noErr {
            ring.write(channel, count: Int(frameCount))
        }
        return status
    }

    /// Runs on `queue`.
    private func drain() {
        guard let channel = drainBuffer.floatChannelData?[0] else { return }
        let count = ring.read(into: channel, maxCount: Int(drainBuffer.frameCapacity))
        let dropped = ring.droppedSamples
        if dropped > reportedDrops {
            Logger.error("Audio capture dropped \(dropped - reportedDrops) samples")
            reportedDrops = dropped
        }
        guard count > 0 else { return }
        drainBuffer.frameLength = AVAudioFrameCount(count)
        if let samples = converter.convert(drainBuffer) {
            onSamples(samples)
        }
    }

    /// Stops the device, then delivers the samples still in the ring buffer.
    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        queue.sync {
            drainTimer?.cancel()
            drainTimer = nil
            drain()
        }
    }

    deinit { stop() }
}
