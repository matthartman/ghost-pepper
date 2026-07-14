# SpeechAnalyzer Transcription Backend Design

**Status:** Approved

## Goal

Add Apple's on-device `SpeechAnalyzer` and `SpeechTranscriber` as an optional speech model on macOS 26 and newer without changing Ghost Pepper's current default model or behavior on older macOS versions.

## Context

Ghost Pepper already presents speech recognition as a model choice rather than a backend choice:

- `SpeechModelCatalog` describes selectable WhisperKit and FluidAudio models.
- `ModelManager` loads the selected model and routes batch transcription to its backend.
- `SpeechTranscriber` serializes requests through `ModelManager`.
- Dictation, meeting transcription, and transcription-lab reruns all consume that shared batch path.
- The app deploys to macOS 14, so all SpeechAnalyzer references must be isolated behind macOS 26 availability checks.

Apple positions SpeechAnalyzer as an on-device model for dictation, meetings, conversations, and long-form audio. The linked [Inscribe benchmark](https://get-inscribe.com/blog/apple-speech-api-benchmark.html) reports better English LibriSpeech accuracy and speed than Whisper Small, but it covers read English speech on one machine rather than Ghost Pepper's full workload. That evidence justifies adding an option, not changing the default.

Live SDK checks on macOS 26.2 established the asset behavior:

- `SpeechTranscriber.isAvailable` is true.
- An installed `en_US` locale transcribed generated speech without a download.
- A supported but uninstalled `es_ES` locale returned a non-nil `AssetInventory.assetInstallationRequest`.

The model is supplied and retained by macOS, but missing locale assets can still require a system-managed download. Ghost Pepper will initiate that download through `AssetInventory`; it will not own or delete the resulting files.

## Product Decisions

1. SpeechAnalyzer is a selectable option only on macOS 26 and newer.
2. Whisper Small English remains the default. Existing selections are preserved.
3. Ghost Pepper does not automatically choose SpeechAnalyzer or silently fall back to Whisper.
4. Missing locale assets are installed through Apple's `AssetInventory` API.
5. The first implementation uses batch transcription. Progressive live results are deferred until measured latency shows a need.
6. Existing FluidAudio speaker filtering remains disabled for SpeechAnalyzer in this iteration.
7. The app remains deployable on macOS 14.

## Approaches Considered

### Direct batch adapter — selected

Add a focused Apple backend and route it through the existing catalog and `ModelManager`. This is the smallest change that makes SpeechAnalyzer work in dictation, meeting chunks, and transcription-lab reruns.

### Batch plus progressive recording session

Feed audio into SpeechAnalyzer throughout a recording and finalize on stop. This could reduce stop latency, but it introduces volatile-result replacement, cancellation, and streaming lifecycle work before latency has been measured.

### General speech-backend refactor

Extract WhisperKit, FluidAudio, and SpeechAnalyzer into a new protocol hierarchy. This would produce a more uniform abstraction but would rewrite stable code without being necessary for the new option.

## Architecture

### Speech model catalog

Add `.speechAnalyzer` to `SpeechBackendKind` and a descriptor with a stable ID such as `apple_speech-analyzer`.

The descriptor:

- appears in `SpeechModelCatalog.availableModels` only under `#available(macOS 26, *)`;
- identifies its storage as system-managed rather than app-managed;
- uses a picker label such as `Apple SpeechAnalyzer (System model)`;
- reports a size of `Managed by macOS`;
- does not support speaker filtering;
- does not change `SpeechModelCatalog.defaultModelID`.

### AppleSpeechAnalyzerBackend

Create `GhostPepper/Transcription/AppleSpeechAnalyzerBackend.swift`, with the entire type marked `@available(macOS 26.0, *)`. Qualify framework types as `Speech.SpeechTranscriber` to avoid colliding with Ghost Pepper's existing `SpeechTranscriber` class.

The backend owns four responsibilities:

1. Resolve Ghost Pepper's language setting to a supported SpeechTranscriber locale.
2. Install a missing locale asset through `AssetInventory` while reporting progress.
3. Convert Ghost Pepper's 16 kHz mono Float32 samples to the best compatible analyzer format.
4. Run and finalize one analysis session, returning the concatenated plain-text results.

It does not own model selection, UI state, cleanup, meeting chunking, speaker filtering, or fallback policy.

### ModelManager integration

`ModelManager` keeps the Apple backend in availability-safe storage, following the existing Qwen pattern used by the macOS 14 deployment target.

When the selected descriptor uses `.speechAnalyzer`:

- model loading resolves the selected locale and prepares its system asset;
- `downloadProgress` mirrors the `AssetInstallationRequest.progress` value;
- batch transcription delegates to the Apple backend;
- switching models clears the retained backend instance;
- cache deletion is never attempted for the system-managed model.

No broad backend protocol refactor is part of this work.

### App and settings integration

`AppState.loadSpeechModel` passes the preferred language to `ModelManager`. Changing the language while SpeechAnalyzer is selected prepares the new locale before the next recording.

The language picker keeps its existing values. For SpeechAnalyzer, the `auto` choice is displayed as `System language` because SpeechTranscriber requires a locale; it resolves from `Locale.current` rather than detecting an arbitrary spoken language. Other backends continue to display `Auto-detect`.

The Models screen displays SpeechAnalyzer as `Managed by macOS`. It never offers download or delete controls for the row; selection initiates any required system download through the normal model-loading state.

Add `NSSpeechRecognitionUsageDescription` to the app's Info.plist. Ghost Pepper does not request `SFSpeechRecognizer` server-recognition authorization because SpeechAnalyzer transcription remains on-device.

## Data Flow

### Selecting SpeechAnalyzer

1. The user selects Apple SpeechAnalyzer in Settings.
2. `AppState` persists the stable model ID and calls `loadSpeechModel` with the current language setting.
3. `ModelManager` creates the Apple backend under a macOS 26 availability guard.
4. The backend resolves the locale through `Speech.SpeechTranscriber.supportedLocale(equivalentTo:)`.
5. If `AssetInventory.assetInstallationRequest(supporting:)` returns a request, the backend calls `downloadAndInstall()` and reports its progress.
6. `ModelManager` becomes ready only after locale support is available.

### Transcribing audio

1. Existing Ghost Pepper code calls `SpeechTranscriber.transcribe(audioBuffer:language:)`.
2. `ModelManager` routes the request to the prepared Apple backend.
3. The backend creates a `Speech.SpeechTranscriber` with the `.transcription` preset.
4. It obtains the best compatible format and converts the input samples.
5. It starts consuming `transcriber.results` before analysis begins.
6. It supplies a finished `AsyncStream<AnalyzerInput>` to `SpeechAnalyzer.analyzeSequence`.
7. If analysis returns a last sample time, it calls `finalizeAndFinish(through:)`; otherwise it calls `cancelAndFinishNow()`.
8. It concatenates result text in delivery order, trims surrounding whitespace, and returns nil for an empty transcript.

Finalization is mandatory. Closing the input stream alone is not considered completion.

### Changing language

When SpeechAnalyzer is selected and the language changes, Ghost Pepper reruns the preparation path for the new locale. An unsupported locale fails visibly instead of using English or another backend. Previously installed system assets remain managed by macOS.

## Error Handling

Use a focused backend error type for:

- SpeechTranscriber unavailable on the current hardware;
- unsupported system or explicitly selected locale;
- missing compatible audio format;
- audio-buffer conversion failure;
- asset installation failure;
- analysis or finalization failure.

Model preparation errors flow into the existing `ModelManager.state == .error` presentation. Runtime transcription errors are recorded through the existing model debug logger and return nil, matching current transcription behavior.

There is no automatic backend fallback. A user who selected SpeechAnalyzer should receive a SpeechAnalyzer failure, not an unannounced Whisper result.

## Model Inventory Behavior

SpeechAnalyzer differs from the existing downloadable models:

- its implementation ships with macOS;
- locale assets are downloaded, retained, shared, and updated by macOS;
- Ghost Pepper has no filesystem cache path for it;
- Ghost Pepper cannot safely promise deletion of the system asset.

The inventory row therefore uses a system-managed status and suppresses both download and trash actions. Required locale installation happens when the model is selected, with the existing active download progress presentation.

## Testing

All implementation follows test-first development.

Automated coverage will verify:

- the model appears on macOS 26 and remains absent on older systems;
- the default model ID remains unchanged;
- the descriptor is system-managed and does not support speaker filtering;
- `ModelManager` routes load and transcription requests to the Apple backend;
- `auto` resolves from the system locale and explicit language codes resolve predictably;
- unsupported locales fail without silent fallback;
- Float32 input is converted into the analyzer's compatible PCM format, including clipping at the valid sample range;
- the Models screen renders the system-managed status without delete or download actions;
- language changes reprepare SpeechAnalyzer only when it is selected.

The production Speech framework lifecycle also requires live macOS 26 verification because CI may not have the locale asset installed. On the development Mac, verification must:

1. select Apple SpeechAnalyzer and install a missing locale asset when applicable;
2. transcribe known spoken audio through Ghost Pepper's backend;
3. confirm the result returns only after analyzer finalization;
4. confirm selection survives relaunch;
5. rerun a saved Transcription Lab recording;
6. run the full automated test suite and a normal app build.

## Files Expected to Change

- `GhostPepper/Transcription/SpeechModelCatalog.swift`
- `GhostPepper/Transcription/AppleSpeechAnalyzerBackend.swift` (new)
- `GhostPepper/Transcription/ModelManager.swift`
- `GhostPepper/AppState.swift`
- `GhostPepper/ModelInventory.swift`
- `GhostPepper/UI/ModelInventoryViews.swift`
- `GhostPepper/UI/SettingsWindow.swift`
- `GhostPepper/Info.plist`
- `GhostPepper.xcodeproj/project.pbxproj`
- focused tests under `GhostPepperTests/`

## Non-Goals

- Making SpeechAnalyzer the default or adding an automatic model policy.
- Removing or changing WhisperKit, FluidAudio, Parakeet, or Qwen behavior.
- Progressive live transcription or partial-result UI.
- SpeechAnalyzer-backed speaker filtering or diarization.
- App-managed deletion of Apple speech assets.
- Changing Ghost Pepper's minimum deployment target.

## Acceptance Criteria

- macOS 26+ users can select Apple SpeechAnalyzer anywhere the speech model picker appears.
- macOS 14 and 15 builds remain supported and never reference unavailable APIs at runtime.
- Selecting SpeechAnalyzer installs a missing supported locale asset and exposes progress.
- Dictation, meeting chunks, and transcription-lab reruns use SpeechAnalyzer through the existing shared path.
- Existing defaults, selections, and non-Apple backends are unchanged.
- Unsupported locales and framework failures are visible and never trigger a silent fallback.
- The system-managed model cannot be deleted from Ghost Pepper.
- Automated tests, the full build, and live macOS 26 transcription verification pass.
