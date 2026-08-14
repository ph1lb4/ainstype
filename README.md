<p align="center">
  <img src="icon.png" alt="ainstype" width="128" height="128">
</p>

<h1 align="center">ainstype</h1>

<p align="center">A macOS menubar app for local speech-to-text. Hold a hotkey, speak, release — your transcription is pasted into the focused app.</p>

- Fully local transcription via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML, Apple Silicon)
- Live transcription — text is pasted incrementally as you speak (on by default)
- Custom dictionary for domain-specific terms
- History of the last 5 transcriptions, to recover text if a paste didn't land
- Runs in the menu bar, starts at login

## Quick Start

1. Download the latest **`ainstype-x.y.z.dmg`** from the [Releases page](https://github.com/ph1lb4/ainstype/releases/latest).
2. Open the DMG and drag **ainstype** into your **Applications** folder.
3. Launch ainstype from Applications — it runs in the menu bar (no dock icon).
4. Grant **Input Monitoring** and **Accessibility** permissions when prompted.

Hold **Right Cmd** and speak. Release to transcribe and paste.

The DMG bundles the WhisperKit model, so there's no first-run download.

## Privacy

Everything runs on-device. Audio is transcribed locally with WhisperKit and never leaves your Mac. The only network request the app makes is the one-time WhisperKit model download on first launch (or you can bundle the model so there's no download at all).

## Model

Transcription uses **`openai_whisper-large-v3-v20240930_turbo_632MB`** — a CoreML conversion of OpenAI's [Whisper large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo) with compressed weights (about 600 MB), downloaded from Argmax's [whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml) Hugging Face repo and run via [WhisperKit](https://github.com/argmaxinc/WhisperKit).

- Original Whisper source code: [openai/whisper](https://github.com/openai/whisper) (MIT)
- Original model weights: [openai/whisper-large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo)
- CoreML model used by the app: [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml)
- Inference runtime: [argmaxinc/WhisperKit](https://github.com/argmaxinc/WhisperKit) (MIT)

## Requirements

- macOS 14+ (Sonoma)
- Apple Silicon (M1/M2/M3/M4)
- Xcode Command Line Tools (`xcode-select --install`)

## Build from source

```bash
swift build && swift run
```

On first launch, the app downloads the WhisperKit model (about 600 MB) unless one is already bundled.

## Build & Distribute

```bash
./build_app.sh
```

This builds a signed `.app` bundle and creates a DMG. Optionally bundles the WhisperKit model so users skip the first-run download.

## Configuration

Edit `~/.config/ainstype/config.toml`:

```toml
language = "en"           # optional, auto-detect if omitted
live_transcription = true # paste text incrementally while you speak (on by default; toggle from the menu)
clipboard_hold_seconds = 0 # keep the latest transcription on the clipboard this long (0 = off, 5 or 10 in Settings)

[recording]
hotkey = "cmd_r"         # cmd, cmd_r, alt, alt_r, ctrl, ctrl_r
```

**Live transcription** (on by default) pastes your words in chunks every couple of seconds as you keep talking, instead of all at once on release. Text appears with a ~2–4s lag (Whisper revises the most recent words as it hears more context), and only finalized text is pasted — so it never garbles or duplicates. Toggle it from the menu bar or via the config key above.

**When text doesn't land**, a bubble appears at the bottom of the screen with the transcription and a Copy button. It goes away after about six seconds (a little longer while the pointer is over it) and never takes keyboard focus, so you can hit Copy and then ⌘V straight into the app you were dictating into. A synthetic ⌘V reports nothing back, so delivery is checked against the focused element afterwards: if there was nothing focused that accepts text — a Finder window, the desktop, a plain web page — that counts as a failure and you get the bubble.

**Keep on clipboard** (Settings → Keep on clipboard: Off / 5 / 10 seconds) leaves the transcription on the clipboard for that long, so a manual ⌘V always works; afterwards whatever you had copied before comes back. This applies to one-shot mode only — with live insertion on, the clipboard is never touched, so dictating can't interfere with what you have copied. **Copy Latest** in the menu bar puts the last transcription back on the clipboard for good, live mode included.

The **History** tab (menu bar → Recent Transcriptions…, or the Dictionary window) keeps the last five transcriptions so you can copy text back if a paste didn't land in the focused app.

Custom terms in `~/.config/ainstype/dictionary.toml`:

```toml
[terms]
words = ["Kubernetes", "TypeScript", "PostgreSQL"]

[replacements]
"kube control" = "kubectl"
"post gress" = "Postgres"
```
