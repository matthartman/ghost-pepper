<img src="./app-icon.png" width="80" alt="Ghost Pepper">

# Ghost Pepper

**100% local** hold-to-talk speech-to-text for macOS. Hold Control to record, release to transcribe and paste. No cloud APIs, no data leaves your machine.

**[Download the latest release](https://github.com/matthartman/ghost-pepper/releases/latest/download/GhostPepper.dmg)** — macOS 14.0+, Apple Silicon (M1+)

## Features

- **Hold Control to talk** — release to transcribe and paste into any text field
- **Runs entirely on your Mac** — models run locally via Apple Silicon, nothing is sent anywhere
- **Smart cleanup** — local LLM removes filler words and handles self-corrections
- **Menu bar app** — lives in your menu bar, no dock icon, launches at login
- **Customizable** — edit the cleanup prompt, pick your mic, toggle features on/off

## How it works

Ghost Pepper uses open-source models that run entirely on your Mac. Models download automatically and are cached locally.

### Speech models

| Model | Size | Best for |
|---|---|---|
| Whisper tiny.en | ~75 MB | Fastest, English only |
| **Whisper small.en** (default) | ~466 MB | Best accuracy, English only |
| Whisper small (multilingual) | ~466 MB | Multi-language support |
| Whisper Large v3 Turbo | ~954 MB | High-accuracy multilingual Whisper |
| whisper.cpp Large v3 Turbo (Q5_0 quantized) | ~574 MB | Smaller ggml download with local `whisper.cpp` runtime |
| whisper.cpp Large v3 Turbo (F16 full precision) | ~1.5 GB | Full-precision ggml model for local `whisper.cpp` runtime |
| Parakeet v3 (25 languages) | ~1.4 GB | Multi-language via [FluidAudio](https://github.com/FluidInference/FluidAudio) |
| Qwen3-ASR 0.6B int8 (50+ languages) | ~900 MB | Highest multilingual quality, macOS 15+ required |

### Cleanup models

| Model | Size | Speed |
|---|---|---|
| **Qwen 3.5 0.8B** (default) | ~535 MB | Very fast (~1-2s) |
| Qwen 3.5 2B | ~1.3 GB | Fast (~4-5s) |
| Qwen 3.5 4B | ~2.8 GB | Full quality (~5-7s) |

Speech models are powered by [WhisperKit](https://github.com/argmaxinc/WhisperKit), [whisper.cpp](https://github.com/ggml-org/whisper.cpp), and [FluidAudio](https://github.com/FluidInference/FluidAudio). Cleanup models powered by [LLM.swift](https://github.com/eastriverlee/LLM.swift). All models served by [Hugging Face](https://huggingface.co/).

## Getting started

**Download the app:**
1. Download [GhostPepper.dmg](https://github.com/matthartman/ghost-pepper/releases/latest/download/GhostPepper.dmg)
2. Open the DMG, drag Ghost Pepper to Applications
3. Grant Microphone and Accessibility permissions when prompted
4. Hold Control and speak

> **"Apple could not verify" warning?** On macOS Sequoia, you may see a Gatekeeper warning the first time you open the app. Go to **System Settings > Privacy & Security**, scroll down, and click **Open Anyway** next to the Ghost Pepper message. Click **Confirm** in the popup. You only need to do this once.

**Build from source:**
1. Clone the repo
2. Open `GhostPepper.xcodeproj` in Xcode
3. Build and run (Cmd+R)

## Permissions

| Permission | Why |
|---|---|
| Microphone | Record your voice |
| Accessibility | Global hotkey and paste via simulated keystrokes |

## Good to know

- **Launch at login** is enabled by default on first run. You can toggle it off in Settings.
- **Everything stays local** — transcription history and recordings are stored on your Mac only. Nothing is sent to the cloud. You can clear history anytime in Settings.

## Acknowledgments

Built with [WhisperKit](https://github.com/argmaxinc/WhisperKit), [LLM.swift](https://github.com/eastriverlee/LLM.swift), [Hugging Face](https://huggingface.co/), and [Sparkle](https://sparkle-project.org/).

## License

MIT

## Why "Ghost Pepper"?

All models run locally, no private data leaves your computer. And it's spicy to offer something for free that other apps have raised $80M to build.

## Enterprise / managed devices

Ghost Pepper requires Accessibility permission, which normally needs admin access to grant. On managed devices, IT admins can pre-approve this via an MDM profile (Jamf, Kandji, Mosaic, etc.) using a Privacy Preferences Policy Control (PPPC) payload:

| Field | Value |
|---|---|
| Bundle ID | `com.github.matthartman.ghostpepper` |
| Team ID | `BBVMGXR9AY` |
| Permission | Accessibility (`com.apple.security.accessibility`) |
