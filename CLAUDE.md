# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is ainstype

A macOS menubar app for speech-to-text. Hold a hotkey, speak, release — your words are transcribed fully locally using WhisperKit (CoreML on Apple Silicon) and pasted into the focused app. No cloud, no network calls beyond the one-time model download.

## Commands

```bash
swift build                    # debug build
swift run                      # run debug build
swift test                     # unit tests (Tests/AinstypeAppTests)
swift build -c release         # release build
./build_app.sh                 # build .app bundle + sign + DMG + notarize
```

## Architecture

The pipeline flows: **hotkey → record → transcribe → dictionary replacements → clipboard/paste**.

### Source files (`Sources/AinstypeApp/`)

- `App.swift` — `@main` entry point, `NSApplicationDelegate`, sleep/wake handling.
- `StatusMenuController.swift` — `NSStatusItem` menu bar UI, state machine (setup/downloading/loading/idle/recording/processing), first-run setup dialog, Start at Login toggle, Copy Latest. Surfaces all failures through `RecoveryBubble`.
- `HotkeyMonitor.swift` — `NSEvent.addGlobalMonitorForEvents(.flagsChanged)` for modifier key hotkeys. Requires Input Monitoring permission.
- `AudioRecorder.swift` — `AVAudioEngine` capture, outputs 16kHz mono Float32 array. Pins the capture device (`InputDeviceSelection`; defaults to system default, user can pick "builtin") via CoreAudio so recording needn't force Bluetooth headphones into the low-quality call profile; `AudioDevices` enumerates input devices for the Settings picker.
- `Pipeline.swift` — Orchestrates: WhisperKit transcribe → dictionary replacements → clipboard paste. Two-phase warmUp: fast GPU load (~5-10s), then background ANE specialization.
- `ModelState.swift` — Persists downloaded model path and ANE specialization state to `~/.config/ainstype/model_state.json`.
- `Dictionary.swift` — Reads `dictionary.toml`, applies spoken→written replacements. (Whisper initial-prompt biasing was removed: WhisperKit 0.17.0–1.0.0 returns empty transcriptions when `promptTokens` is set; the `[terms]` TOML section is preserved on save for the Python CLI.)
- `Clipboard.swift` — `NSPasteboard` + `CGEvent` Cmd+V paste (no osascript). Requires Accessibility permission. `RestoreLedger` handles restoring the user's clipboard after a synthetic paste; `copyAndHold` implements the `clipboard_hold_seconds` setting and `copyPinned` leaves text on the clipboard for good (cancelling any pending restore).
- `RecoveryBubble.swift` — Non-activating floating panel shown bottom-center when a transcription can't be delivered (paste/insert failed, transcription errored) or on "Copy Latest". Shows the text with a Copy button, auto-dismisses after 10s, never steals keyboard focus so ⌘V still goes to the user's app. Replaces the previous `UNUserNotification` error path.
- `Config.swift` — TOMLKit-based config, reads `~/.config/ainstype/` files.
- `LaunchAgent.swift` — Manages `~/Library/LaunchAgents/com.ainstype.menubar.plist` for auto-start at login.
- `Logger.swift` — Writes to `os_log` and `~/Library/Logs/ainstype/app.log`.

## Configuration

Config dir: `~/.config/ainstype/`.

Files:
- `config.toml` — User overrides (hotkey, language, `recording.input_device`, `clipboard_hold_seconds`)
- `dictionary.toml` — Custom terms for Whisper biasing + spoken→written replacements
- `model_state.json` — Cached WhisperKit model path and ANE specialization state

## Build & Distribution

The app is built and distributed as a signed/notarized `.app` bundle in a DMG.

- Code signing identity: override via the `SIGN_IDENTITY` env var (e.g. `Developer ID Application: Your Name (TEAMID)`); team id via `TEAM_ID`. Defaults in `build_app.sh` are the maintainer's.
- Notarization keychain profile: `ainstype-notary`
- Build script: `build_app.sh` (prompts to bundle WhisperKit model; set `BUNDLE_MODEL=yes|no` to skip prompt)
- WhisperKit model: `openai_whisper-large-v3-v20240930_turbo_632MB` (~616MB). Bundled in DMG or downloaded on first run.

## Key conventions

- Targets macOS 14+ (Sonoma), Apple Silicon only.
- SPM dependencies: WhisperKit (1.0.0+), TOMLKit (0.6.0+).
- Two-phase model loading: GPU-first for fast startup (~5-10s), then background ANE specialization for optimal inference.
