# Text Cleanup Feature — Design Spec

**Date:** 2026-03-19
**Status:** Draft

## Overview

Add optional local LLM-powered text cleanup to WhisperCat. After WhisperKit transcribes audio, pass the text through a Qwen 2.5 1.5B model running via MLX to remove filler words and handle self-corrections. Runs 100% locally on Apple Silicon.

## Data Flow

```
Current:  Audio → WhisperKit transcribe → paste
New:      Audio → WhisperKit transcribe → [if cleanup on] → MLX cleanup → paste
```

## Components

### TextCleanupManager

Manages the MLX model lifecycle. Analogous to `ModelManager` for WhisperKit.

- Loads Qwen 2.5 1.5B MLX model from Hugging Face on first use (~1GB download)
- Keeps model resident in memory while cleanup is enabled
- Unloads model when cleanup is toggled off (frees ~1GB RAM)
- Reports state: idle, loading, ready, error
- `@MainActor` ObservableObject like ModelManager

### TextCleaner

Performs the actual text cleanup using the loaded model.

- Accepts raw transcription `String`
- Sends text to MLX model with a system prompt
- Returns cleaned `String?`
- Runs on a background thread
- Returns original text if cleanup fails (graceful degradation)

### System Prompt

```
Clean up this speech transcription. Remove filler words (um, uh, like, you know, so, basically, literally, right, I mean). If the speaker corrects themselves (e.g. "actually let's say X", "no wait X", "I mean X", "sorry, X"), keep only the final correction. Do not change the meaning, tone, or add any words. Output only the cleaned text, nothing else.
```

## UI Changes

Add to menu bar dropdown:
- **Cleanup picker:** `Off | On` (default: **On**)
- When toggled on for the first time, shows "Loading cleanup model..." status
- Model download progress not shown in v1 (future enhancement)

## Integration with Existing Code

### AppState Changes

- Add `cleanupEnabled: Bool` property (default `true`)
- Add `textCleanupManager: TextCleanupManager`
- Add `textCleaner: TextCleaner`
- In `initialize()`: if cleanup enabled, load the cleanup model after WhisperKit model loads
- In `stopRecordingAndTranscribe()`: after WhisperKit transcription, if cleanup enabled and model ready, run text through TextCleaner before pasting

### MenuBarView Changes

- Add cleanup picker below input device picker

## Dependencies

- **mlx-swift** — Apple's MLX framework Swift bindings via SPM
- **mlx-swift-examples/LLM** — MLX community LLM inference utilities (provides tokenizer, generation pipeline)
- **Model:** `mlx-community/Qwen2.5-1.5B-Instruct-4bit` (~1GB) from Hugging Face

## Performance

- **Latency:** ~400ms per cleanup on M1 for short text (~50 words)
- **RAM:** ~1GB additional when cleanup model is loaded
- **Total app footprint:** ~1.5GB with both WhisperKit and cleanup models loaded
- **First run:** ~1GB model download from Hugging Face

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Model fails to load | Cleanup auto-disables, error shown in menu bar, transcription still works without cleanup |
| Cleanup inference fails | Paste original uncleaned text, no error shown |
| Model download fails | Show error, allow retry, transcription works without cleanup |
| Toggle off while loading | Cancel load, unload model |

## Scope

### In
- Filler word removal via LLM
- Self-correction handling ("actually let's say X")
- On/Off toggle in menu bar (default: On)
- Model download on first enable
- Graceful fallback to raw text on failure

### Out (future)
- Grammar correction
- Punctuation improvement
- Custom cleanup prompts
- Download progress indicator
- Multiple cleanup model options
