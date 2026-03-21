<img src="app-icon.png" width="80" alt="Ghost Pepper">

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

Ghost Pepper uses two open-source models that download automatically on first launch:

| | Model | Size | What it does |
|---|---|---|---|
| Speech-to-text | [WhisperKit](https://github.com/argmaxinc/WhisperKit) (small.en) | ~466 MB | Transcribes your speech to text |
| Text cleanup | [Qwen 2.5](https://huggingface.co/Qwen) (1.5B + 3B) | ~3 GB | Removes filler words and self-corrections |

Models are served by [Hugging Face](https://huggingface.co/) and cached locally after first download.

## Getting started

**Download the app:**
1. Download [GhostPepper.dmg](https://github.com/matthartman/ghost-pepper/releases/latest/download/GhostPepper.dmg)
2. Open the DMG, drag Ghost Pepper to Applications
3. Grant Microphone and Accessibility permissions when prompted
4. Hold Control and speak

**Build from source:**
1. Clone the repo
2. Open `GhostPepper.xcodeproj` in Xcode
3. Build and run (Cmd+R)

## Permissions

| Permission | Why |
|---|---|
| Microphone | Record your voice |
| Accessibility | Global hotkey and paste via simulated keystrokes |

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
