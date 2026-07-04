import XCTest
import AVFoundation
import WhisperKit
@testable import AinstypeApp

// MARK: - Hotkey modifier handling

/// Device-specific modifier bits in NSEvent.modifierFlags.rawValue (NX_DEVICE…MASK).
private let devLeftCmd: UInt = 0x08
private let devRightCmd: UInt = 0x10
private let devLeftCtrl: UInt = 0x01
private let devRightCtrl: UInt = 0x2000
private let genericCmd = NSEvent.ModifierFlags.command.rawValue
private let genericCtrl = NSEvent.ModifierFlags.control.rawValue

final class HotkeyFlagTests: XCTestCase {
    private var presses = 0
    private var releases = 0

    private func makeMonitor(_ key: String) -> HotkeyMonitor {
        presses = 0
        releases = 0
        return HotkeyMonitor(
            keyName: key,
            onPress: { [self] in presses += 1 },
            onRelease: { [self] in releases += 1 }
        )!
    }

    func testSoloRightCommandPressAndRelease() {
        let m = makeMonitor("cmd_r")
        m.processFlagsChange(keyCode: 54, rawFlags: genericCmd | devRightCmd)
        XCTAssertEqual(presses, 1)
        m.processFlagsChange(keyCode: 54, rawFlags: 0)
        XCTAssertEqual(releases, 1)
    }

    /// The dual-modifier bug: releasing right-cmd while left-cmd is still held
    /// keeps the generic .command flag set, so release was never detected and
    /// recording ran until the safety timer.
    func testReleaseDetectedWhileOtherCommandKeyStillHeld() {
        let m = makeMonitor("cmd_r")
        // Left cmd down: not our key, ignored.
        m.processFlagsChange(keyCode: 55, rawFlags: genericCmd | devLeftCmd)
        XCTAssertEqual(presses, 0)
        // Right cmd down while left held.
        m.processFlagsChange(keyCode: 54, rawFlags: genericCmd | devLeftCmd | devRightCmd)
        XCTAssertEqual(presses, 1)
        // Right cmd up, left still held — .command still set, device bit gone.
        m.processFlagsChange(keyCode: 54, rawFlags: genericCmd | devLeftCmd)
        XCTAssertEqual(releases, 1, "release must fire even though generic ⌘ flag is still set by the other cmd key")
    }

    /// Same scenario for control, whose right-device bit (0x2000) is far from
    /// the left one — guards the keycode→device-mask table.
    func testReleaseDetectedWhileOtherControlKeyStillHeld() {
        let m = makeMonitor("ctrl_r")
        m.processFlagsChange(keyCode: 62, rawFlags: genericCtrl | devLeftCtrl | devRightCtrl)
        XCTAssertEqual(presses, 1)
        m.processFlagsChange(keyCode: 62, rawFlags: genericCtrl | devLeftCtrl)
        XCTAssertEqual(releases, 1)
    }

    /// Some remapping tools synthesize flagsChanged without device bits; the
    /// generic modifier flag must remain a working fallback.
    func testGenericFlagFallbackWithoutDeviceBits() {
        let m = makeMonitor("cmd_r")
        m.processFlagsChange(keyCode: 54, rawFlags: genericCmd)
        XCTAssertEqual(presses, 1)
        m.processFlagsChange(keyCode: 54, rawFlags: 0)
        XCTAssertEqual(releases, 1)
    }

    func testOtherKeycodeIgnored() {
        let m = makeMonitor("cmd_r")
        m.processFlagsChange(keyCode: 55, rawFlags: genericCmd | devLeftCmd)
        XCTAssertEqual(presses, 0)
        XCTAssertEqual(releases, 0)
    }
}

// MARK: - Silence gate

final class AudioGateTests: XCTestCase {
    private let sr: Float = 16000

    private func sine(seconds: Float, amplitude: Float) -> [Float] {
        let n = Int(seconds * sr)
        return (0..<n).map { amplitude * sin(2 * .pi * 440 * Float($0) / sr) }
    }

    func testEmptyBufferRejected() {
        XCTAssertFalse(AudioGate.shouldTranscribe([], sampleRate: sr))
    }

    func testDigitalSilenceRejected() {
        XCTAssertFalse(AudioGate.shouldTranscribe([Float](repeating: 0, count: 16000), sampleRate: sr))
    }

    func testMicNoiseFloorRejected() {
        XCTAssertFalse(AudioGate.shouldTranscribe(sine(seconds: 1, amplitude: 0.002), sampleRate: sr))
    }

    func testSpeechLevelAccepted() {
        XCTAssertTrue(AudioGate.shouldTranscribe(sine(seconds: 1, amplitude: 0.05), sampleRate: sr))
    }

    func testAccidentalTapTooShortRejected() {
        XCTAssertFalse(AudioGate.shouldTranscribe(sine(seconds: 0.1, amplitude: 0.5), sampleRate: sr))
    }
}

// MARK: - Tap conversion

final class TapConverterTests: XCTestCase {
    private func format(_ rate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    }

    private func rampBuffer(format: AVAudioFormat, frames: Int, startValue: Float, slope: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        let data = buffer.floatChannelData![0]
        for i in 0..<frames {
            data[i] = startValue + slope * Float(i)
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    /// Feed two consecutive 48kHz buffers carrying one continuous linear ramp.
    /// If the converter's input block ever hands the same buffer twice, the
    /// ramp restarts mid-stream — a large backwards jump in the output.
    func testDownsampledRampHasNoDuplicatedAudio() throws {
        let input = format(48000)
        let target = format(16000)
        let converter = try XCTUnwrap(TapConverter(from: input, to: target))

        let frames = 4096
        let slope: Float = 1.0 / Float(2 * frames)
        let b1 = rampBuffer(format: input, frames: frames, startValue: 0, slope: slope)
        let b2 = rampBuffer(format: input, frames: frames, startValue: slope * Float(frames), slope: slope)

        var out: [Float] = []
        out.append(contentsOf: try XCTUnwrap(converter.convert(b1)))
        out.append(contentsOf: try XCTUnwrap(converter.convert(b2)))

        // Expected output length: 8192 / 3 ≈ 2730, minus bounded filter latency.
        XCTAssertGreaterThan(out.count, 2300, "lost audio during conversion")
        XCTAssertLessThanOrEqual(out.count, 2731, "produced more audio than was captured")

        // Skip the resampler's initial edge, then the ramp must never step
        // backwards by more than a hair (duplication rewinds it massively).
        for i in 65..<out.count {
            XCTAssertGreaterThan(
                out[i], out[i - 1] - 0.005,
                "output ramp jumped backwards at sample \(i) — duplicated input audio"
            )
        }
    }

    func testPassthroughWhenFormatsMatch() throws {
        let f = format(16000)
        let converter = try XCTUnwrap(TapConverter(from: f, to: f))
        let buffer = rampBuffer(format: f, frames: 512, startValue: 0.1, slope: 0.0001)
        let out = try XCTUnwrap(converter.convert(buffer))
        XCTAssertEqual(out.count, 512)
        XCTAssertEqual(out[0], 0.1, accuracy: 1e-6)
    }
}

// MARK: - Holdback for cross-chunk replacements

final class HoldbackSplitTests: XCTestCase {
    private func makeManager() -> DictionaryManager {
        DictionaryManager(path: URL(fileURLWithPath: "/nonexistent/ainstype-tests/dictionary.toml"))
    }

    func testTrailingPrefixOfMultiWordRuleIsHeld() {
        let d = makeManager() // defaults include "new line"
        let (emit, hold) = d.holdbackSplit(" this is new")
        XCTAssertEqual(emit, " this is")
        XCTAssertEqual(hold, " new")
    }

    func testNoHoldWithoutTrailingPrefix() {
        let d = makeManager()
        let (emit, hold) = d.holdbackSplit(" hello there")
        XCTAssertEqual(emit, " hello there")
        XCTAssertEqual(hold, "")
    }

    func testHoldIsCaseInsensitive() {
        let d = makeManager() // defaults include "open paren"
        let (emit, hold) = d.holdbackSplit(" say OPEN")
        XCTAssertEqual(emit, " say")
        XCTAssertEqual(hold, " OPEN")
    }

    func testEntireTextCanBeHeld() {
        let d = makeManager()
        let (emit, hold) = d.holdbackSplit(" new")
        XCTAssertEqual(emit, "")
        XCTAssertEqual(hold, " new")
    }

    func testTwoWordPrefixOfThreeWordRuleIsHeld() {
        let d = makeManager()
        d.setReplacements(["full stop now": "."])
        let (emit, hold) = d.holdbackSplit(" say full stop")
        XCTAssertEqual(emit, " say")
        XCTAssertEqual(hold, " full stop")
    }

    func testCompleteSingleWordRuleIsNotHeld() {
        let d = makeManager()
        d.setReplacements(["cat": "dog", "new line": "\n"])
        let (emit, hold) = d.holdbackSplit(" a cat")
        XCTAssertEqual(emit, " a cat")
        XCTAssertEqual(hold, "")
    }

    func testPrefixWordMidTextIsNotHeld() {
        let d = makeManager()
        let (emit, hold) = d.holdbackSplit(" new stuff here")
        XCTAssertEqual(emit, " new stuff here")
        XCTAssertEqual(hold, "")
    }
}

// MARK: - Live text assembly

final class LiveTextAssemblerTests: XCTestCase {
    private func makeAssembler(replacements: [String: String]? = nil) -> LiveTextAssembler {
        let d = DictionaryManager(path: URL(fileURLWithPath: "/nonexistent/ainstype-tests/dictionary.toml"))
        if let replacements { d.setReplacements(replacements) }
        return LiveTextAssembler(dictionary: d)
    }

    func testFirstChunkDropsLeadingSpace() {
        let a = makeAssembler()
        XCTAssertEqual(a.assemble(" hello world"), "hello world")
    }

    func testLaterChunksKeepSeparatorSpace() {
        let a = makeAssembler()
        _ = a.assemble(" hello there")
        XCTAssertEqual(a.assemble(" friend"), " friend")
    }

    func testDuplicateBoundaryWordDropped() {
        let a = makeAssembler()
        _ = a.assemble(" hello there")
        XCTAssertEqual(a.assemble(" there again"), " again")
    }

    func testWhitespaceOnlyReturnsNil() {
        let a = makeAssembler()
        XCTAssertNil(a.assemble("   "))
    }

    func testReplacementWithinOneChunk() {
        let a = makeAssembler()
        XCTAssertEqual(a.assemble(" say new line now"), "say \n now")
    }

    func testReplacementAcrossChunksViaHoldback() {
        let a = makeAssembler()
        XCTAssertEqual(a.assemble(" this is new"), "this is")
        XCTAssertEqual(a.assemble(" line here"), " \n here")
        XCTAssertEqual(a.transcript, "this is \n here")
    }

    func testFlushEmitsHeldTail() {
        let a = makeAssembler()
        XCTAssertEqual(a.assemble(" it is new"), "it is")
        XCTAssertEqual(a.assemble("", flush: true), " new")
        XCTAssertEqual(a.transcript, "it is new")
    }

    func testFlushCombinesHeldTextWithFinalTail() {
        let a = makeAssembler()
        XCTAssertEqual(a.assemble(" press new"), "press")
        XCTAssertEqual(a.assemble(" line done", flush: true), " \n done")
    }

    func testFlushPendingRecoversHeldTextOnErrorPath() {
        let a = makeAssembler()
        XCTAssertEqual(a.assemble(" go new"), "go")
        XCTAssertEqual(a.flushPending(), " new")
        XCTAssertEqual(a.transcript, "go new")
    }

    func testFirstChunkFullyHeld() {
        let a = makeAssembler()
        XCTAssertNil(a.assemble(" new"))
        XCTAssertEqual(a.assemble(" line"), "\n")
        XCTAssertEqual(a.transcript, "\n")
    }
}

// MARK: - Clipboard restore ledger

final class RestoreLedgerTests: XCTestCase {
    func testSinglePasteRestoresPreviousOnce() {
        var ledger = RestoreLedger()
        let gen = ledger.recordPaste(previousClipboard: "user data")
        XCTAssertEqual(ledger.takeRestore(for: gen), "user data")
        XCTAssertNil(ledger.takeRestore(for: gen), "restore must be one-shot")
    }

    /// Two dictations inside the restore window: the stale first timer must do
    /// nothing, and the second must restore the *original* user clipboard, not
    /// the first transcription it happened to find on the pasteboard.
    func testRapidPastesRestoreOriginalClipboardExactlyOnce() {
        var ledger = RestoreLedger()
        let gen1 = ledger.recordPaste(previousClipboard: "user data")
        let gen2 = ledger.recordPaste(previousClipboard: "transcription one")
        XCTAssertNil(ledger.takeRestore(for: gen1), "superseded timer must not restore")
        XCTAssertEqual(ledger.takeRestore(for: gen2), "user data")
    }

    func testEmptyOriginalClipboardIsNotRestored() {
        var ledger = RestoreLedger()
        let gen = ledger.recordPaste(previousClipboard: nil)
        XCTAssertNil(ledger.takeRestore(for: gen))
    }
}

// MARK: - Decoding options

final class DecodingOptionsTests: XCTestCase {
    /// Dictionary biasing must stay unwired until the upstream bug is fixed:
    /// WhisperKit returns EMPTY transcriptions whenever promptTokens is set
    /// (reproduced with synthesized speech that decodes fine without it;
    /// verified broken in 0.17.0, 0.18.0 and 1.0.0).
    func testPromptTokensStayDisabled() {
        XCTAssertNil(Pipeline.makeDecodingOptions(language: nil).promptTokens)
    }

    /// With no configured language, detection must be requested explicitly —
    /// WhisperKit's prefill otherwise silently defaults to English.
    func testAutoDetectEnabledWhenNoLanguageConfigured() {
        let options = Pipeline.makeDecodingOptions(language: nil)
        XCTAssertNil(options.language)
        XCTAssertTrue(options.detectLanguage)
    }

    func testExplicitLanguageDisablesDetection() {
        let options = Pipeline.makeDecodingOptions(language: "de")
        XCTAssertEqual(options.language, "de")
        XCTAssertFalse(options.detectLanguage)
    }
}

// MARK: - Config

final class LiveInsertionConfigTests: XCTestCase {
    func testLiveInsertionRequiresAutoPaste() {
        var c = Config()
        c.liveTranscription = true
        c.autoPaste = false
        XCTAssertFalse(c.liveInsertionEnabled, "auto_paste=false means clipboard-only; nothing may be typed")
        c.autoPaste = true
        XCTAssertTrue(c.liveInsertionEnabled)
        c.liveTranscription = false
        XCTAssertFalse(c.liveInsertionEnabled)
    }
}

// MARK: - Dictionary data preservation

final class DictionaryRoundTripTests: XCTestCase {
    /// The Words/Names UI was removed (Whisper prompt biasing is broken
    /// upstream), but dictionary.toml is shared with the Python CLI — a save
    /// from this app must never destroy the [terms] section.
    func testTermsSectionSurvivesLoadSaveRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("dictionary.toml")
        try """
        [replacements]
        'foo' = 'bar'

        [terms]
        names = [ 'Ahoi Kapptn!' ]
        words = [ 'WhisperKit' ]
        """.write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let d = DictionaryManager(path: path)
        d.setReplacements(["foo": "baz"])
        d.save()

        let content = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(content.contains("Ahoi Kapptn!"), "names lost on save")
        XCTAssertTrue(content.contains("WhisperKit"), "words lost on save")
        XCTAssertTrue(content.contains("baz"), "replacement edit not saved")
    }
}

// MARK: - Dictionary thread safety

final class DictionaryConcurrencyTests: XCTestCase {
    /// Live mode applies replacements every second while the settings window may
    /// mutate the dictionary on the main thread. Run reads and writes
    /// concurrently; under TSan (or a torn dictionary) this crashes/reports.
    func testConcurrentReadsAndWrites() {
        let d = DictionaryManager(path: URL(fileURLWithPath: "/nonexistent/ainstype-tests/dictionary.toml"))
        DispatchQueue.concurrentPerform(iterations: 400) { i in
            switch i % 4 {
            case 0:
                d.setReplacements(["term\(i)": "value\(i)", "new line": "\n"])
            case 1:
                _ = d.allReplacements
            case 2:
                _ = d.applyReplacements("hello new line term\(i) world")
            default:
                _ = d.holdbackSplit(" trailing new")
            }
        }
    }
}
