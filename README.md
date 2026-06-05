<p align="center">
  <img src="icon.png" alt="ainstype" width="128" height="128">
</p>

<h1 align="center">ainstype</h1>

<p align="center">A macOS menubar app for local speech-to-text. Hold a hotkey, speak, release — your transcription is pasted into the focused app.</p>

- Fully local transcription via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML, Apple Silicon)
- Custom dictionary for domain-specific terms
- Runs in the menu bar, starts at login

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

## Quick Start

1. Download the latest **`ainstype-x.y.z.dmg`** from the [Releases page](https://github.com/ph1lb4/ainstype/releases/latest).
2. Open the DMG and drag **ainstype** into your **Applications** folder.
3. Launch ainstype from Applications — it runs in the menu bar (no dock icon).
4. Grant **Input Monitoring** and **Accessibility** permissions when prompted.

Hold **Right Cmd** and speak. Release to transcribe and paste.

The DMG bundles the WhisperKit model, so there's no first-run download.

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
language = "en"          # optional, auto-detect if omitted

[recording]
hotkey = "cmd_r"         # cmd, cmd_r, alt, alt_r, ctrl, ctrl_r
```

Custom terms in `~/.config/ainstype/dictionary.toml`:

```toml
[terms]
words = ["Kubernetes", "TypeScript", "PostgreSQL"]

[replacements]
"kube control" = "kubectl"
"post gress" = "Postgres"
```
