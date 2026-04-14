<div align="center">

<img src="./app-icon.png" width="128" alt="Ghost Pepper">

# Ghost Pepper

**Voice dictation and meeting transcription<br>without data ever leaving your machine.**

100% local models = 100% privacy

<br>

<img src="./privacy-flow.svg" width="600" alt="Your Voice → Your Mac (on device) → Your Text">

<br>

<a href="https://github.com/matthartman/ghost-pepper/releases/latest/download/GhostPepper.dmg">
  <img src="https://img.shields.io/badge/Download_for_Mac-FF6600?style=for-the-badge&logo=apple&logoColor=white" alt="Download for Mac" height="44">
</a>

<br>

macOS 14.0+ &middot; Apple Silicon (M1+) &middot; Free & open source

<br>

[![GitHub stars](https://img.shields.io/github/stars/matthartman/ghost-pepper?style=social)](https://github.com/matthartman/ghost-pepper)
&nbsp;
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
&nbsp;
![100% Local](https://img.shields.io/badge/100%25-Local-FF6600)
&nbsp;
![50+ Languages](https://img.shields.io/badge/50%2B-Languages-blue)

</div>

---

<table>
<tr>
<td width="50%" valign="top">

### Speech-to-text
Hold Control to talk, release to transcribe and paste into any text field. Works everywhere.

</td>
<td width="50%" valign="top">

### Meeting transcription
Record calls with notes, transcript, and AI-generated summaries — saved as local markdown.

</td>
</tr>
<tr>
<td width="50%" valign="top">

### Smart cleanup
Local LLM removes filler words, fixes self-corrections, and cleans up your speech automatically.

</td>
<td width="50%" valign="top">

### Completely private
All models run on your Mac via Apple Silicon. Nothing is uploaded, tracked, or stored in the cloud.

</td>
</tr>
</table>

---

## What people are saying

<a href="https://www.producthunt.com/products/ghost-pepper-2">
  <img src="./testimonials/ryan-hoover.png" width="700" alt="Ryan Hoover — Product Hunt">
</a>

<table>
<tr>
<td width="50%">
<a href="https://x.com/davemorin/status/2041989209951703404">
  <img src="./testimonials/dave-morin.png" width="380" alt="Dave Morin tweet">
</a>
</td>
<td width="50%">
<a href="https://x.com/nickywonka/status/2042052415600386345">
  <img src="./testimonials/nick-saltarelli.png" width="380" alt="Nick Saltarelli tweet">
</a>
</td>
</tr>
<tr>
<td colspan="2">
<a href="https://x.com/mignano/status/2041611062777410012">
  <img src="./testimonials/michael-mignano.png" width="380" alt="Michael Mignano tweet">
</a>
</td>
</tr>
</table>

---

## Getting started

1. Download [GhostPepper.dmg](https://github.com/matthartman/ghost-pepper/releases/latest/download/GhostPepper.dmg)
2. Open the DMG, drag Ghost Pepper to Applications
3. Grant Microphone and Accessibility permissions when prompted
4. Hold Control and speak

> **"Apple could not verify" warning?** On macOS Sequoia, you may see a Gatekeeper warning the first time you open the app. Go to **System Settings > Privacy & Security**, scroll down, and click **Open Anyway** next to the Ghost Pepper message. Click **Confirm** in the popup. You only need to do this once.

**Build from source:**
1. Clone the repo
2. Open `GhostPepper.xcodeproj` in Xcode
3. Build and run (Cmd+R)

## Privacy audit

Every core feature runs 100% on your Mac — verified by [AI code review](PRIVACY_AUDIT.md). No trust required, just point Claude at the repo and ask.

| Feature | Status | What was checked |
|---|---|---|
| Speech-to-text | :white_check_mark: Local | WhisperKit/FluidAudio inference, no audio sent anywhere |
| Text cleanup | :white_check_mark: Local | Qwen LLM runs on-device via LLM.swift |
| Audio recording | :white_check_mark: Local | AVAudioEngine + ScreenCaptureKit, no streaming |
| Meeting transcription & storage | :white_check_mark: Local | Chunked transcription, markdown files on disk |
| Summary generation | :white_check_mark: Local | Local LLM summarization, no cloud API |
| OCR & screen capture | :white_check_mark: Local | Apple Vision framework, on-device |
| File storage | :white_check_mark: Local | Markdown to local filesystem, no cloud sync |
| Analytics & telemetry | :white_check_mark: None | No Firebase, Mixpanel, Sentry, or any tracking SDK |

**Optional cloud features** (disabled by default, require your own API keys): Zo AI chat, Trello integration, Granola meeting import. Model downloads are one-time from Hugging Face.

> **Verify it yourself:** run `cat PRIVACY_AUDIT.md` in Claude Code and ask it to review the codebase against the audit prompt.

## Models

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

Speech models powered by [WhisperKit](https://github.com/argmaxinc/WhisperKit). Cleanup models powered by [LLM.swift](https://github.com/eastriverlee/LLM.swift). All models served by [Hugging Face](https://huggingface.co/).

## Permissions

| Permission | Why |
|---|---|
| Microphone | Record your voice |
| Accessibility | Global hotkey and paste via simulated keystrokes |

## Good to know

- **Launch at login** is enabled by default on first run. You can toggle it off in Settings.
- **Everything stays local** — transcription history and recordings are stored on your Mac only. Nothing is sent to the cloud. You can clear history anytime in Settings.

---

<div align="center">

### Why "Ghost Pepper"?

All models run locally — no private data leaves your computer.<br>
It's spicy to offer something for free that other apps have raised $80M to build.

<br>

Built with [WhisperKit](https://github.com/argmaxinc/WhisperKit), [LLM.swift](https://github.com/eastriverlee/LLM.swift), [Hugging Face](https://huggingface.co/), and [Sparkle](https://sparkle-project.org/). &middot; MIT License

</div>

## Enterprise / managed devices

Ghost Pepper requires Accessibility permission, which normally needs admin access to grant. On managed devices, IT admins can pre-approve this via an MDM profile (Jamf, Kandji, Mosaic, etc.) using a Privacy Preferences Policy Control (PPPC) payload:

| Field | Value |
|---|---|
| Bundle ID | `com.github.matthartman.ghostpepper` |
| Team ID | `BBVMGXR9AY` |
| Permission | Accessibility (`com.apple.security.accessibility`) |
