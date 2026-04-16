<div align="center">

<img src="./app-icon.png" width="80" alt="Ghost Pepper">

# Ghost Pepper

**100% private** on-device voice models for speech-to-text and meeting transcription on macOS. No cloud APIs, no data leaves your machine.

<a href="https://github.com/matthartman/ghost-pepper/releases/latest/download/GhostPepper.dmg">
  <img src="https://img.shields.io/badge/Download_for_Mac-FF6600?style=for-the-badge&logo=apple&logoColor=white" alt="Download for Mac" height="40">
</a>

macOS 14.0+ · Apple Silicon (M1+) · Free & open source

[![GitHub stars](https://img.shields.io/github/stars/matthartman/ghost-pepper?style=social)](https://github.com/matthartman/ghost-pepper)
&nbsp;
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
&nbsp;
![100% Local](https://img.shields.io/badge/100%25-Local-FF6600)
&nbsp;
![50+ Languages](https://img.shields.io/badge/50%2B-Languages-blue)

</div>

## Features

- **Hold Control to talk** — release to transcribe and paste into any text field
- **Meeting transcription** — record calls with notes, transcript, and AI-generated summaries saved as markdown
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
| Parakeet v3 (25 languages) | ~1.4 GB | Multi-language via [FluidAudio](https://github.com/FluidInference/FluidAudio) |
| Qwen3-ASR 0.6B int8 (50+ languages) | ~900 MB | Highest multilingual quality, macOS 15+ required |

### Cleanup models

| Model | Size | Speed |
|---|---|---|
| **Qwen 3.5 0.8B** (default) | ~535 MB | Very fast (~1-2s) |
| Qwen 3.5 2B | ~1.3 GB | Fast (~4-5s) |
| Qwen 3.5 4B | ~2.8 GB | Full quality (~5-7s) |

Speech models powered by [WhisperKit](https://github.com/argmaxinc/WhisperKit). Cleanup models powered by [RunAnywhere Swift SDK](https://github.com/RunanywhereAI/runanywhere-sdks) with `RunAnywhereLlamaCPP` (Metal-accelerated local llama.cpp runtime). All models served by [Hugging Face](https://huggingface.co/).

### MetalRT cleanup backend (this fork)

This fork keeps the same hold-to-talk flow and cleanup prompt, but replaces the cleanup inference backend from LLM.swift to RunAnywhere's Swift SDK.

- Backend swap: `LLM.swift` cleanup calls were replaced with `RunAnywhere.generateStream(...)` in `GhostPepper/Cleanup/TextCleanupManager.swift`
- Prompt parity: cleanup prompt and prompt-construction path remain unchanged (`TextCleaner` + `CleanupPromptBuilder`)
- Model parity: same Qwen family and quantization are preserved:
  - `Qwen3.5-0.8B-Q4_K_M.gguf` (default)
  - `Qwen3.5-2B-Q4_K_M.gguf`
  - `Qwen3.5-4B-Q4_K_M.gguf`
- Latency logging: set `SHOW_LATENCY_BADGE = true` in `TextCleanupManager.swift` to print per-cleanup latency in ms:
  - `[MetalRT] Cleanup: 347ms (Qwen 3.5 0.8B Q4_K_M (Very fast))`

#### Hardware and OS for testing

- macOS 14+
- Apple Silicon Mac (M1+)
- Xcode 16+

#### Latency comparison workflow

To produce a visible before/after latency comparison in this fork:

1. Build and run upstream Ghost Pepper (LLM.swift backend), run identical dictation samples, and capture cleanup latency
2. Build and run this fork (RunAnywhere backend), run the same samples, and capture the `[MetalRT] Cleanup: ...ms` lines
3. Compare median / p95 cleanup latency across both runs

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

## Privacy audit

Every core feature runs 100% on your Mac — verified by AI code review. No trust required, just point Claude at the repo and ask.

| Feature | Status | What was checked |
|---|---|---|
| Speech-to-text | :white_check_mark: Local | WhisperKit/FluidAudio inference, no audio sent anywhere |
| Text cleanup | :white_check_mark: Local | Qwen LLM runs on-device via RunAnywhere (`RunAnywhereLlamaCPP`) |
| Audio recording | :white_check_mark: Local | AVAudioEngine + ScreenCaptureKit, no streaming |
| Meeting transcription & storage | :white_check_mark: Local | Chunked transcription, markdown files on disk |
| Summary generation | :white_check_mark: Local | Local LLM summarization, no cloud API |
| OCR & screen capture | :white_check_mark: Local | Apple Vision framework, on-device |
| File storage | :white_check_mark: Local | Markdown to local filesystem, no cloud sync |
| Analytics & telemetry | :white_check_mark: None | No Firebase, Mixpanel, Sentry, or any tracking SDK |

**Optional cloud features** (disabled by default, require your own API keys): Zo AI chat, Trello integration, Granola meeting import. Model downloads are one-time from Hugging Face.

> **Verify it yourself:** run `cat PRIVACY_AUDIT.md` in Claude Code and ask it to review the codebase against the audit prompt. The [full audit](PRIVACY_AUDIT.md) includes the exact prompt and detailed file-level results.

## Good to know

- **Launch at login** is enabled by default on first run. You can toggle it off in Settings.
- **Everything stays local** — transcription history and recordings are stored on your Mac only. Nothing is sent to the cloud. You can clear history anytime in Settings.

## Acknowledgments

Built with [WhisperKit](https://github.com/argmaxinc/WhisperKit), [RunAnywhere Swift SDK](https://github.com/RunanywhereAI/runanywhere-sdks), [Hugging Face](https://huggingface.co/), and [Sparkle](https://sparkle-project.org/).

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
