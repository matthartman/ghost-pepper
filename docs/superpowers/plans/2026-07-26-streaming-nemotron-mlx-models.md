# Streaming Nemotron MLX Models Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task by task.

**Goal:** Add the two NVIDIA Nemotron 0.6B ASR models to GhostPepper as MLX-backed, streaming-only transcription options, including the upstream MLXAudioSwift compatibility needed by the older English checkpoint.

**Architecture:** Keep model execution behind GhostPepper's existing recording-transcription session boundary. MLXAudioSwift owns Nemotron model loading and incremental RNN-T state. GhostPepper selects an immutable Hugging Face repository per catalog entry and feeds resampled 16 kHz audio to a per-recording MLX stream session. The older English checkpoint remains the same runtime path, with narrowly scoped compatibility in MLXAudioSwift for its legacy NeMo config and packed pointwise-convolution layout.

**Tech Stack:** Swift 6, Swift Package Manager, MLX / MLXNN, MLXAudioSwift, XcodeGen, XCTest / Swift Testing, Hugging Face model artifacts.

---

## Task 1: Reproduce legacy Nemotron incompatibility in MLXAudioSwift

**Files:**

- Modify: `/Users/jesse/git/mlx-audio-swift/Tests/MLXAudioSTTTests.swift`

- [ ] Clone `Blaizzy/mlx-audio-swift` into an isolated local checkout, create `agent/support-legacy-nemotron-streaming`, resolve dependencies, and run the existing `NemotronASRTests` as the clean baseline.
- [ ] Add a focused test that decodes the older checkpoint's real legacy structure: nested `decoder.prednet`, nested `joint.jointnet`, vocabulary under `joint`, absent prompt configuration, and encoder-derived attention context.
- [ ] Add a focused sanitizer test with synthetic packed 8-bit pointwise-convolution weights, scales, and biases. Assert the output is dequantized, gains the Conv1d singleton kernel dimension, and drops obsolete quantization metadata.
- [ ] Run `swift test --filter NemotronASRTests` and record the expected failures before changing production code.

## Task 2: Add minimal legacy-checkpoint compatibility

**Files:**

- Modify: `/Users/jesse/git/mlx-audio-swift/Sources/MLXAudioSTT/Models/NemotronASR/NemotronASRConfig.swift`
- Modify: `/Users/jesse/git/mlx-audio-swift/Sources/MLXAudioSTT/Models/NemotronASR/NemotronASRModel.swift`
- Test: `/Users/jesse/git/mlx-audio-swift/Tests/MLXAudioSTTTests.swift`

- [ ] Decode both current flattened Nemotron 3.5 configuration and the older nested NeMo configuration without changing current defaults.
- [ ] Make the prompt kernel genuinely optional so the English-only checkpoint does not invent multilingual prompt parameters.
- [ ] Dequantize only legacy packed pointwise Conv1d weights and reshape them from `[out, in]` to `[out, 1, in]` during weight sanitization.
- [ ] Run the focused test until it passes, then run the complete MLXAudioSwift test suite and release build.
- [ ] Commit the tests and compatibility implementation with a detailed root-cause explanation.

## Task 3: Qualify both real Nemotron checkpoints

**Files:**

- Reuse: `/tmp/ghost-pepper-asr-benchmark.LaGrfk`
- Reuse: local GhostPepper utterance fixtures selected by the existing benchmark harness

- [ ] Load `animaslabs/nemotron-speech-streaming-en-0.6b-mlx-8bit` from the clean patched checkout and transcribe the same local utterances through `NemotronASRStreamSession`.
- [ ] Load `mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit` and run the same streaming path as a regression check.
- [ ] Capture exact commit IDs, model revisions, hardware, utterance duration, transcript output, wall time, real-time factor, and peak memory evidence.
- [ ] Confirm the results are reproducible from the committed checkout rather than the earlier temporary exploratory patch.

## Task 4: Publish the MLXAudioSwift compatibility PR

**Files:**

- Inspect: upstream `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, pull-request template, README, and repository instructions

- [ ] After testing, verify whether the upstream repository permits agent-authored or agent-assisted contributions and obey any disclosure/template requirements.
- [ ] If permitted, create `obra/mlx-audio-swift`, push the tested branch, and open a draft PR against `Blaizzy/mlx-audio-swift:main`.
- [ ] Explain the root cause, narrow compatibility behavior, automated tests, real-checkpoint evidence, benchmark timings, hardware, and model revisions.
- [ ] Identify the author as Codex and state that Codex is happy to have its human partner perform additional work requested by maintainers.
- [ ] Verify the rendered PR body and report the PR URL and CI state.

## Task 5: Add the MLX Nemotron backend to GhostPepper

**Files:**

- Modify: `project.yml`
- Modify: `GhostPepper/Transcription/SpeechModelCatalog.swift`
- Modify: `GhostPepper/Transcription/ModelManager.swift`
- Modify: `GhostPepper/Transcription/RecordingSessionCoordinator.swift`
- Test: `GhostPepperTests/SpeechTranscriberTests.swift`
- Test: `GhostPepperTests/ModelManagerTests.swift`
- Test: `GhostPepperTests/RuntimeModelInventoryTests.swift`

- [ ] Add failing catalog tests for both streaming-only Nemotron descriptors, exact model repositories, MLX backend identity, availability, and inventory presentation.
- [ ] Add failing recording-session tests proving MLX selection creates independent incremental sessions, forwards audio chunks, flushes exactly once, and never uses an offline transcription API.
- [ ] Add the pinned MLXAudioSwift dependency and the smallest backend adapter needed by `ModelManager`.
- [ ] Route both models exclusively through the recording streaming-session path.
- [ ] Preserve current WhisperKit, FluidAudio, Qwen, and SpeechAnalyzer behavior.
- [ ] Run focused tests and commit the catalog/backend integration.

## Task 6: Verify GhostPepper end to end

**Files:**

- Verify: generated `GhostPepper.xcodeproj`
- Verify: GhostPepper runtime model inventory and recording flow

- [ ] Regenerate the Xcode project with XcodeGen and ensure the resolved MLXAudioSwift revision is reproducible.
- [ ] Run focused transcription/catalog/inventory tests, then the full GhostPepper test suite.
- [ ] Build and launch GhostPepper, download each Nemotron model through the normal UI, record real utterances, and verify final transcript delivery for both.
- [ ] Record runtime timings and memory separately from automated test evidence.
- [ ] Inspect `git status`, review the complete diff, commit all intended GhostPepper changes, and report any external acceptance boundary still open.
