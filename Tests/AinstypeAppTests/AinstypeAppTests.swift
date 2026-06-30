import XCTest
@testable import AinstypeApp

final class DictionaryTests: XCTestCase {
    /// A manager pointed at a non-existent file keeps the built-in default
    /// replacements and ignores whatever is in the real user config dir.
    private func makeManager() -> DictionaryManager {
        DictionaryManager(path: URL(fileURLWithPath: "/nonexistent/ainstype-tests/dictionary.toml"))
    }

    func testDefaultReplacements() {
        let d = makeManager()
        XCTAssertEqual(d.applyReplacements("open paren"), "(")
        XCTAssertEqual(d.applyReplacements("hello new line world"), "hello \n world")
    }

    func testWordBoundaryDoesNotMatchInsideWords() {
        let d = makeManager()
        d.setReplacements(["cat": "dog"])
        XCTAssertEqual(d.applyReplacements("category cat"), "category dog")
    }

    func testLongestPhraseAppliedFirst() {
        let d = makeManager()
        d.setReplacements(["new": "N", "new line": "\n"])
        // The longer phrase must win; otherwise "new" would consume it first.
        XCTAssertEqual(d.applyReplacements("new line"), "\n")
    }

    func testCaseInsensitive() {
        let d = makeManager()
        d.setReplacements(["hello": "hi"])
        XCTAssertEqual(d.applyReplacements("HELLO Hello hello"), "hi hi hi")
    }

    func testNonWordTermFallsBackToPlainReplace() {
        let d = makeManager()
        d.setReplacements([":)": "🙂"])
        XCTAssertEqual(d.applyReplacements("hi :)"), "hi 🙂")
    }
}

final class ConfigTests: XCTestCase {
    func testModelNameMapping() {
        var c = Config()
        c.applyTOML("""
        [transcription]
        model = "mlx-community/whisper-large-v3-turbo"
        """)
        XCTAssertEqual(c.transcription.model, "openai_whisper-large-v3-v20240930_turbo_632MB")
    }

    func testUnknownModelPassesThrough() {
        var c = Config()
        c.applyTOML("""
        [transcription]
        model = "openai_whisper-tiny"
        """)
        XCTAssertEqual(c.transcription.model, "openai_whisper-tiny")
    }

    func testScalarOverrides() {
        var c = Config()
        c.applyTOML("""
        auto_paste = false
        live_transcription = false
        language = "de"
        [recording]
        hotkey = "alt"
        sample_rate = 8000
        """)
        XCTAssertFalse(c.autoPaste)
        XCTAssertFalse(c.liveTranscription)
        XCTAssertEqual(c.language, "de")
        XCTAssertEqual(c.recording.hotkey, "alt")
        XCTAssertEqual(c.recording.sampleRate, 8000)
    }

    func testUnknownKeysKeepDefaults() {
        var c = Config()
        // Valid TOML, but none of the keys we recognize — everything stays default.
        c.applyTOML("""
        some_unknown_key = "value"
        [unknown_section]
        foo = 1
        """)
        XCTAssertEqual(c.recording.hotkey, "cmd_r")
        XCTAssertTrue(c.autoPaste)
    }
}

final class HotkeyMonitorTests: XCTestCase {
    func testSupportedKeyInitSucceeds() {
        let monitor = HotkeyMonitor(keyName: "cmd_r", onPress: {}, onRelease: {})
        XCTAssertNotNil(monitor)
    }

    func testUnsupportedKeyInitFailsInsteadOfCrashing() {
        let monitor = HotkeyMonitor(keyName: "bogus_key", onPress: {}, onRelease: {})
        XCTAssertNil(monitor)
    }
}
