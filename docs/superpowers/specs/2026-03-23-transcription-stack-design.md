# Transcription Stack Design

## Goal

Add first-class configurable recording chords, cleanup backend/model selection, OCR-informed cleanup, and a persistent correction system without turning the current app into a single `AppState` blob.

## Current Constraints

- The app currently hardcodes a Control-only hold-to-talk path in `GhostPepper/Input/HotkeyMonitor.swift`.
- The settings UI in `GhostPepper/UI/SettingsWindow.swift` exposes microphone, cleanup enablement, and prompt editing, but not shortcut or backend selection.
- Cleanup currently uses local GGUF models through `LLM.swift` in `GhostPepper/Cleanup/TextCleanupManager.swift` and `GhostPepper/Cleanup/TextCleaner.swift`.
- The project currently targets macOS 14.0 in `project.yml`.
- Apple Foundation Models are available on macOS 26.0+ and require runtime availability checks.
- OCR will require Screen Recording permission.

## Non-Goals

- Sequential shortcut support
- Promise of universal Globe-key support before hardware validation
- Large refactors unrelated to the requested stack
- Silent unconditional learning from post-paste OCR diffs

## Recommended Approach

Add a few narrow seams where the new behavior needs them:

- A reusable chord system for recording actions
- A pluggable cleanup backend layer
- A pluggable OCR context layer
- A persistent correction store with deterministic rules

This keeps the repo's current shape intact while making later branches additive instead of tangled.

## Branch Stack

### 1. `codex/chord-actions`

Replace the single-purpose hotkey monitor with a chord system that supports:

- side-specific modifiers
- simultaneous push-to-talk and toggle-to-talk actions
- prefix-aware matching for overlapping chords
- a custom SwiftUI-backed recorder UI that captures low-level key events

Core types:

- `KeyChord`
  A persisted simultaneous chord made of physical keys, not generic modifier flags
- `ChordAction`
  Initial cases: `pushToTalk`, `toggleToTalk`
- `ChordBindingStore`
  Persistence, validation, defaults, and conflict reporting
- `ChordRecorder`
  Settings-side capture and display
- `ChordEngine`
  Runtime event matching and state transitions

Runtime rules:

- If the pressed key set exactly matches `pushToTalk`, start recording immediately unless the set is still a strict prefix of a longer configured chord.
- If the pressed key set exactly matches `toggleToTalk`, toggle immediately.
- Releasing any required push-to-talk key stops hold recording immediately.
- Re-entering the toggle chord stops toggle recording.
- If the pressed set can no longer become any configured chord, reset.

Globe support is best effort only. If the low-level event path exposes Globe distinctly, record and match it. If not, the recorder must refuse it instead of pretending support exists.

### 2. `codex/cleanup-model-picker`

Add first-class cleanup model selection in settings.

The current cleanup system loads a fast model and a full model and chooses between them internally. This branch should separate:

- cleanup enabled/disabled
- local cleanup model policy

Recommended local policy choices:

- `Automatic`
  Preserve current short-vs-long text behavior
- `Fast model only`
- `Full model only`

This keeps the current local backend behavior available while making the chosen model explicit in the UI.

### 3. `codex/foundation-model-cleanup`

Make cleanup backend-pluggable while keeping the project target at macOS 14.0.

Add a cleanup backend abstraction with two initial implementations:

- `LocalLLMCleanupBackend`
  Existing GGUF-based cleanup through `LLM.swift`
- `FoundationModelsCleanupBackend`
  Available only behind compile-time and runtime availability checks on macOS 26.0+

The Foundation Models backend must:

- use `SystemLanguageModel` availability checks
- expose unavailable reasons in settings
- fall back cleanly to the local backend
- keep prompts short because the system model context window is limited

Recommended settings model:

- backend: `Local Models` or `Apple Foundation Models`
- local model policy: `Automatic`, `Fast`, `Full`
- when Foundation Models is selected but unavailable, show status and do not break recording

### 4. `codex/ocr-context`

Add frontmost-window OCR context for cleanup prompts.

Pipeline:

1. Determine the frontmost app/window.
2. Capture the window image.
3. Run high-quality OCR with Vision.
4. Inject the resulting text into the cleanup prompt as:

```text
The full current content of the frontmost window is:
<WINDOW CONTENTS>
...
</WINDOW CONTENTS>
```

OCR requirements:

- Use Vision `VNRecognizeTextRequest` in highest-quality mode, not fast mode.
- Enable language correction.
- Prefer automatic language detection where it helps recognition quality.
- Trim OCR text before prompt injection so cleanup backends do not receive unbounded context.

Permission model:

- Screen Recording permission is required for capture.
- Accessibility remains useful for locating the frontmost focused element and bounds, especially for the later post-paste learning branch.

### 5. `codex/preferred-transcriptions`

Add a persistent local correction store with two user-owned lists:

- preferred transcriptions
  domain-specific words or phrases that should be preserved
- commonly misheard
  deterministic replacement pairs of "probably wrong" -> "probably right"

This layer should not rely only on prompt text. It needs a deterministic preprocessing/postprocessing path so user corrections are predictable even when the cleanup model is unavailable.

Recommended behavior:

- Apply deterministic corrections before cleanup so the cleanup backend sees better text.
- Re-apply preferred transcriptions after cleanup where necessary to protect user-owned vocabulary.
- Feed preferred words into OCR `customWords` where helpful so the OCR branches benefit from the same vocabulary.

### 6. `codex/learn-misheard`

Add a delayed post-paste learning pass.

Pipeline:

1. After paste, wait 15 seconds.
2. Re-locate the destination text input if possible.
3. Capture a targeted image of the pasted region or its containing window.
4. Run high-quality OCR.
5. Compare the pasted text with the observed text.
6. If the user appears to have made a narrow correction, extract a candidate misheard mapping.

This branch must be conservative. Blind auto-learning will poison the correction store.

Learning rules:

- Learn only from narrow substitutions, not large rewrites.
- Reject low-confidence OCR or ambiguous diffs.
- Reject edits that look like formatting or unrelated typing.
- Persist only plausible "spoken wrong" -> "corrected right" replacements.

Recommended product behavior:

- Run the learning pass automatically.
- Store only high-confidence mappings automatically.
- Discard ambiguous cases instead of forcing a guess.

## Cross-Cutting Architecture

### Cleanup Pipeline

The cleanup pipeline should become:

1. raw transcription
2. deterministic correction pass
3. optional OCR context collection
4. optional cleanup backend
5. final paste
6. delayed post-paste learning

This ordering keeps user-owned deterministic corrections from being overwritten by model output.

### Settings and Onboarding

Settings should gain four clear sections:

- `Shortcuts`
- `Cleanup`
- `Context`
- `Corrections`

Onboarding should stay minimal:

- permissions
- microphone choice
- default shortcut behavior
- link into advanced settings

The new controls belong in settings, not in a longer first-run wizard.

### Error Handling

- Invalid or conflicting chords should fail at save time, not at runtime.
- If Screen Recording permission is missing, disable OCR features and show clear status.
- If Foundation Models is unavailable, keep recording functional and fall back cleanly.
- If OCR fails, discard OCR context or learning for that pass rather than blocking transcription.
- If the cleanup backend fails, paste the corrected deterministic text instead of nothing.

## Testing Strategy

Each branch gets TDD and its own regression coverage.

### Branch 1

- side-specific chord serialization
- exact matching
- prefix disambiguation
- push-to-talk semantics
- toggle semantics
- recorder persistence and conflict validation

### Branch 2

- cleanup model selection persistence
- local model policy behavior
- settings state wiring

### Branch 3

- backend selection
- availability-gated Foundation Models behavior
- fallback when Foundation Models is unavailable

### Branch 4

- OCR request configuration
- prompt injection format
- context trimming
- permission gating

### Branch 5

- deterministic correction precedence
- preferred transcription persistence
- commonly misheard replacement behavior

### Branch 6

- learning heuristics for narrow substitutions
- rejection of ambiguous diffs
- OCR-like noisy-input regression tests

## Risks and Guardrails

- Globe support may not be uniformly observable through the event path on all hardware layouts.
- OCR context can become too large for the cleanup backend if left unbounded.
- Silent learning without confidence thresholds will degrade quality over time.
- Foundation Models integration must remain strictly optional while the app still targets macOS 14.0.

## Outcome

This stack keeps the existing app intact while creating four durable seams:

- input bindings
- cleanup backend selection
- OCR context collection
- deterministic corrections and learning

That is the smallest design that supports the requested features without burying everything inside `AppState`.
