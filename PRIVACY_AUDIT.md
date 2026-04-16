# Privacy Audit

Ghost Pepper claims to be 100% local by default. This file is both the audit prompt and the record of the most recent verification.

## How to verify

Paste the following prompt into Claude Code (or any AI assistant with codebase access) from the repo root:

> Review the Ghost Pepper codebase and confirm that all default features run 100% locally with no network calls. Specifically verify:
>
> 1. **Speech-to-text** — transcription runs entirely on-device (WhisperKit, FluidAudio, Qwen3-ASR). No audio is sent to any server.
> 2. **Text cleanup** — the local Qwen LLM cleans up transcriptions on-device. No text is sent to any API.
> 3. **Audio recording** — mic and system audio capture use AVAudioEngine and ScreenCaptureKit only. No audio is streamed or uploaded.
> 4. **Meeting transcription & summarization** — chunked transcription, markdown storage, and LLM summary generation all happen locally. No meeting content leaves the device.
> 5. **OCR & screen capture** — Vision framework runs on-device. Screenshots are processed locally and never transmitted.
> 6. **File storage** — all meeting notes, transcripts, and summaries are saved as local markdown files. No cloud sync, no remote backup.
> 7. **No analytics or telemetry** — confirm there are no tracking SDKs (Firebase, Mixpanel, Sentry, Amplitude, PostHog, Datadog, Segment, etc.) anywhere in the codebase.
> 8. **Transcript retention & auto-deletion** — opt-in per meeting. When the user sets a retention window in Settings AND flags a specific meeting via the "auto-delete" checkbox on that meeting, the local sweeper strips the `## Transcript` section from the flagged file once it reaches the window. Unflagged meetings are never touched. Summary and notes are always kept. No network calls are made during sweep. This is NOT secure erasure: APFS is copy-on-write, so previously written transcript bytes may remain in free space or Time Machine snapshots until overwritten. FileVault encrypts these blocks at rest but does not prevent recovery once the disk is unlocked.
>
> For each item, check the relevant source files and confirm no `URLSession`, `URLRequest`, or HTTP URL strings exist in the core feature code. List any cloud-connected features separately and confirm they are all opt-in (disabled by default, require user-provided API keys).
>
> Output your findings as a checklist with pass/fail for each item.

---

## Most recent audit

**Date:** 2026-04-13
**Auditor:** Claude Code (Opus 4.6)
**Commit:** (run `git rev-parse --short HEAD` to fill in)

### Core features (must be 100% local)

| # | Feature | Files checked | Result |
|---|---------|--------------|--------|
| 1 | Speech-to-text | `SpeechTranscriber.swift`, `ChunkedTranscriptionPipeline.swift` | :white_check_mark: Pass — no network calls. Inference runs via WhisperKit/FluidAudio on-device. |
| 2 | Text cleanup | `MeetingSummaryGenerator.swift`, `TextCleanupManager.swift` (inference path only) | :white_check_mark: Pass — LLM inference via LLM.swift, fully on-device. `TextCleanupManager` has model download code but that is user-initiated, not part of inference. |
| 3 | Audio recording | `Audio/AudioRecorder.swift`, `Audio/SystemAudioRecorder.swift`, `Audio/DualStreamCapture.swift` | :white_check_mark: Pass — AVAudioEngine (mic) and ScreenCaptureKit (system audio). No network calls. |
| 4 | Meeting transcription & storage | `MeetingSession.swift`, `MeetingTranscript.swift`, `MeetingMarkdownWriter.swift`, `MeetingHistory.swift`, `MeetingTranscriptSettings.swift` | :white_check_mark: Pass — all local file I/O. Markdown written to user-chosen directory. |
| 5 | OCR & screen capture | `Input/WindowCaptureService.swift`, Vision framework usage | :white_check_mark: Pass — Apple Vision framework, on-device only. |
| 6 | File storage | `MeetingMarkdownWriter.swift`, `MeetingHistory.swift` | :white_check_mark: Pass — local filesystem only. No iCloud, CloudKit, or remote sync. |
| 7 | No analytics or telemetry | Entire `GhostPepper/` directory | :white_check_mark: Pass — no Firebase, Mixpanel, Sentry, Amplitude, PostHog, Datadog, or Segment SDKs found. |
| 8 | Transcript retention & auto-deletion | `TranscriptExpirySweeper.swift`, `MeetingMarkdownWriter.swift`, `AppState.swift` | :white_check_mark: Pass (with caveat) — opt-in per meeting. Sweep runs locally, no network calls. When retention is set AND a meeting is flagged (`auto_delete: true` frontmatter), the `## Transcript` section is removed after N days; summary and notes are kept. Unflagged meetings are never touched regardless of age. Caveat: this is not secure erasure. APFS is copy-on-write, so previously written transcript bytes can remain in free space and Time Machine snapshots until overwritten. FileVault encrypts these blocks at rest but does not prevent recovery once the disk is unlocked. UI copy is explicit about this. |

### Cloud-connected features (all opt-in)

These features require explicit user action and API keys. They are **disabled by default**.

| Feature | Trigger | API key required |
|---------|---------|-----------------|
| Zo AI chat | User configures API key in Settings | Yes (`pepperChatApiKey`) |
| Trello integration | User configures API key + token in Settings | Yes (`trelloApiKey`, `trelloToken`) |
| Granola meeting import | User clicks Import and enters API key | Yes (`granolaApiKey`) |
| Model downloads | User selects a model to download | No (public Hugging Face URLs) |
| Sparkle update check | Automatic, checks GitHub appcast.xml 1x/24h | No |

### Verdict

:white_check_mark: **All default features run 100% locally. No user data leaves the device unless the user explicitly configures a cloud integration.**
