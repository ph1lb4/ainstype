# ainstype

A macOS menubar app for local speech-to-text. Hold a hotkey, speak, release — your transcription is pasted into the focused app.

- Fully local transcription via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML, Apple Silicon)
- Custom dictionary for domain-specific terms
- Runs in the menu bar, starts at login

## Privacy

Everything runs on-device. Audio is transcribed locally with WhisperKit and never leaves your Mac. The only network request the app makes is the one-time WhisperKit model download on first launch (or you can bundle the model so there's no download at all).

## Requirements

- macOS 14+ (Sonoma)
- Apple Silicon (M1/M2/M3/M4)
- Xcode Command Line Tools (`xcode-select --install`)

## Quick Start

```bash
swift build && swift run
```

On first launch, the app downloads the WhisperKit model (~616MB). Grant Input Monitoring and Accessibility permissions when prompted.

Hold **Right Cmd** and speak. Release to transcribe and paste.

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
