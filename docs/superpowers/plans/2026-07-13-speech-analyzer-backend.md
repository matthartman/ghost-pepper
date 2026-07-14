# SpeechAnalyzer Transcription Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Apple SpeechAnalyzer as an optional, downloadable, on-device transcription model for macOS 26 and newer while preserving Ghost Pepper's existing defaults and macOS 14 deployment target.

**Architecture:** Add one availability-gated batch adapter around `Speech.SpeechTranscriber`, then route it through the existing model catalog and `ModelManager`. A small availability-neutral protocol gives `ModelManager` a real test seam without exposing macOS 26 types to older deployment targets; all recording modes continue to use the existing shared batch path.

**Tech Stack:** Swift 5, SwiftUI, AVFAudio, Speech framework (`SpeechAnalyzer`, `SpeechTranscriber`, and `AssetInventory`), XCTest, Xcode 26.

## Global Constraints

- Apple SpeechAnalyzer is selectable only on macOS 26.0 and newer.
- `SpeechModelCatalog.defaultModelID` remains `openai_whisper-small.en`.
- `MACOSX_DEPLOYMENT_TARGET` remains `14.0`.
- Missing locale assets download through `AssetInventory`; macOS owns, retains, updates, and deletes those assets.
- Ghost Pepper exposes download progress but never exposes manual download or delete actions for the system-managed row.
- The first implementation is batch-only and does not add progressive results, speaker filtering, diarization, or automatic fallback.
- `auto` means `Locale.current` for SpeechAnalyzer and remains `Auto-detect` for existing backends.
- Unsupported locales and framework failures surface through the existing model error state; they never switch backends silently.
- Qualify Apple's class as `Speech.SpeechTranscriber` so it cannot collide with Ghost Pepper's `SpeechTranscriber`.
- Do not request `SFSpeechRecognizer` authorization; SpeechAnalyzer remains on-device.
- Tests exercise descriptors, routing, locale selection, audio conversion, reload behavior, and inventory contracts rather than rendered SwiftUI strings.

Reference design: `docs/superpowers/specs/2026-07-13-speech-analyzer-backend-design.md`

Apple references:

- [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory)
- [WWDC25: Bring advanced speech-to-text to your app with SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)

---

## File and Responsibility Map

- Create `GhostPepper/Transcription/AppleSpeechAnalyzerBackend.swift`: resolve locales, install Apple assets, convert 16 kHz mono Float32 audio, run/finalize analysis, and return plain text.
- Modify `GhostPepper/Transcription/SpeechModelCatalog.swift`: describe the macOS 26 option and its system-managed behavior.
- Modify `GhostPepper/Transcription/ModelManager.swift`: retain the prepared backend, route load/transcribe calls, track locale-sensitive reloads, and avoid cache deletion.
- Modify `GhostPepper/AppState.swift`: pass the preferred language during model preparation and reprepare SpeechAnalyzer after a language change.
- Modify `GhostPepper/ModelInventory.swift`: represent a system-managed model independently from app-owned cache state.
- Modify `GhostPepper/UI/ModelInventoryViews.swift`: render the system-managed status and honor row action capabilities.
- Modify `GhostPepper/UI/ModelsSidebarView.swift`: include SpeechAnalyzer in the usable model picker without app-owned download/delete actions.
- Modify `GhostPepper/UI/OnboardingWindow.swift`: handle the system-managed inventory status in the existing summary view.
- Modify `GhostPepper/UI/SettingsWindow.swift`: show `System language`, trigger locale preparation, and retain existing model selection flows.
- Modify `GhostPepper/Info.plist`: add the Speech framework privacy string without requesting legacy server-recognition authorization.
- Modify `GhostPepper.xcodeproj/project.pbxproj`: add the new backend file to the app target while preserving deployment settings.
- Modify `GhostPepperTests/SpeechTranscriberTests.swift`: cover the descriptor, availability, locale mapping, clipping, and PCM conversion.
- Modify `GhostPepperTests/ModelManagerTests.swift`: cover SpeechAnalyzer load/transcription routing and language-sensitive reloads.
- Modify `GhostPepperTests/GhostPepperTests.swift`: cover AppState language forwarding and conditional repreparation.
- Modify `GhostPepperTests/RuntimeModelInventoryTests.swift`: cover the system-managed row and its disabled actions.

### Task 1: Add the macOS 26 model descriptor

**Files:**
- Modify: `GhostPepperTests/SpeechTranscriberTests.swift`
- Modify: `GhostPepper/Transcription/SpeechModelCatalog.swift`

**Interfaces:**
- Consumes: the existing `SpeechBackendKind`, `SpeechModelDescriptor`, and `SpeechModelCatalog.availableModels` APIs.
- Produces: `.speechAnalyzer`, `SpeechModelCatalog.speechAnalyzer`, `SpeechModelDescriptor.isSystemManaged`, and `SpeechModelDescriptor.automaticLanguageLabel` for later routing and UI tasks.

- [ ] **Step 1: Write the failing catalog tests**

Replace `testSpeechModelCatalogIncludesWhisperAndParakeetModels()` and add the descriptor test in `SpeechTranscriberTests`:

```swift
func testSpeechModelCatalogIncludesModelsSupportedByTheCurrentOS() {
    let ids = SpeechModelCatalog.availableModels.map(\.id)
    let backends = SpeechModelCatalog.availableModels.map(\.backend)

    var expectedIDs = [
        "openai_whisper-tiny.en",
        "openai_whisper-small.en",
        "openai_whisper-small",
        "fluid_parakeet-v3",
    ]
    var expectedBackends: [SpeechBackendKind] = [
        .whisperKit,
        .whisperKit,
        .whisperKit,
        .fluidAudio,
    ]

    if #available(macOS 15, iOS 18, *) {
        expectedIDs.append("fluid_qwen3-asr-0.6b-int8")
        expectedBackends.append(.fluidAudio)
    }
    if #available(macOS 26, *) {
        expectedIDs.append("apple_speech-analyzer")
        expectedBackends.append(.speechAnalyzer)
    }

    XCTAssertEqual(ids, expectedIDs)
    XCTAssertEqual(backends, expectedBackends)
    XCTAssertEqual(SpeechModelCatalog.defaultModelID, "openai_whisper-small.en")
}

func testSpeechAnalyzerDescriptorIsSystemManagedAndDoesNotFilterSpeakers() {
    let model = SpeechModelCatalog.speechAnalyzer

    XCTAssertEqual(model.name, "apple_speech-analyzer")
    XCTAssertEqual(model.backend, .speechAnalyzer)
    XCTAssertEqual(model.pickerTitle, "Apple SpeechAnalyzer")
    XCTAssertEqual(model.variantName, "System model")
    XCTAssertEqual(model.sizeDescription, "Managed by macOS")
    XCTAssertEqual(model.cachePathComponents, [])
    XCTAssertNil(model.fluidAudioVariant)
    XCTAssertTrue(model.isSystemManaged)
    XCTAssertFalse(model.supportsSpeakerFiltering)
    XCTAssertEqual(model.automaticLanguageLabel, "System language")

    if #available(macOS 26, *) {
        XCTAssertEqual(
            SpeechModelCatalog.model(named: "apple_speech-analyzer"),
            model
        )
    } else {
        XCTAssertNil(SpeechModelCatalog.model(named: "apple_speech-analyzer"))
    }

    XCTAssertEqual(
        SpeechModelCatalog.whisperSmallEnglish.automaticLanguageLabel,
        "Auto-detect"
    )
}
```

- [ ] **Step 2: Run the catalog tests and verify the new contract fails**

Run:

```bash
xcodebuild test -project GhostPepper.xcodeproj -scheme GhostPepper -destination 'platform=macOS' -only-testing:GhostPepperTests/SpeechTranscriberTests
```

Expected: compilation fails because `.speechAnalyzer`, `SpeechModelCatalog.speechAnalyzer`, `isSystemManaged`, and `automaticLanguageLabel` do not exist.

- [ ] **Step 3: Implement the descriptor and availability filter**

Add the backend case and computed descriptor behavior in `SpeechModelCatalog.swift`:

```swift
enum SpeechBackendKind: Equatable {
    case whisperKit
    case fluidAudio
    case speechAnalyzer
}
```

Extend the existing `statusName` switch and descriptor properties:

```swift
var statusName: String {
    switch backend {
    case .whisperKit:
        "Whisper \(variantName) (\(pickerTitle.lowercased()))"
    case .fluidAudio:
        "\(pickerTitle) (\(variantName.lowercased()))"
    case .speechAnalyzer:
        pickerTitle
    }
}

var supportsSpeakerFiltering: Bool {
    // Speaker filtering uses a separate diarization pipeline, so any
    // FluidAudio-backed ASR model can participate in filtering.
    backend == .fluidAudio
}

var isSystemManaged: Bool {
    backend == .speechAnalyzer
}

var automaticLanguageLabel: String {
    isSystemManaged ? "System language" : "Auto-detect"
}
```

Add the descriptor beside the existing static model descriptors:

```swift
static let speechAnalyzer = SpeechModelDescriptor(
    name: "apple_speech-analyzer",
    pickerTitle: "Apple SpeechAnalyzer",
    variantName: "System model",
    sizeDescription: "Managed by macOS",
    backend: .speechAnalyzer,
    cachePathComponents: [],
    fluidAudioVariant: nil
)
```

Replace `availableModels` with an append-based implementation that preserves the existing order and adds Apple last:

```swift
static var availableModels: [SpeechModelDescriptor] {
    var models = baseModels
    if #available(macOS 15, iOS 18, *) {
        models.append(qwen3AsrInt8)
    }
    if #available(macOS 26, *) {
        models.append(speechAnalyzer)
    }
    return models
}
```

- [ ] **Step 4: Run the catalog tests and verify they pass**

Run the command from Step 2.

Expected: `SpeechTranscriberTests` passes and the test log ends with `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit the catalog contract**

```bash
git status --short
git add GhostPepper/Transcription/SpeechModelCatalog.swift GhostPepperTests/SpeechTranscriberTests.swift
git commit -m "feat: describe the SpeechAnalyzer model option" -m "Add the stable Apple SpeechAnalyzer model ID only on macOS 26 and newer. Mark it as system-managed, keep Whisper Small English as the default, and expose model-specific automatic-language copy without changing existing backend behavior."
```

### Task 2: Implement locale assets, PCM conversion, and finalized batch analysis

**Files:**
- Create: `GhostPepper/Transcription/AppleSpeechAnalyzerBackend.swift`
- Modify: `GhostPepperTests/SpeechTranscriberTests.swift`
- Modify: `GhostPepper.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: 16 kHz mono Float32 samples and an optional BCP-47 language code (`nil` means `Locale.current`).
- Produces: `SpeechAnalyzerTranscribing.transcribe(audioBuffer:)`, `AppleSpeechAnalyzerBackend.prepare(languageCode:currentLocale:progressHandler:)`, and internal conversion helpers used by ModelManager and unit tests.

- [ ] **Step 1: Write failing locale and conversion tests**

Append this test class to `SpeechTranscriberTests.swift`:

```swift
@MainActor
final class AppleSpeechAnalyzerBackendTests: XCTestCase {
    func testRequestedLocaleUsesExplicitLanguageOrCurrentLocale() throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }

        XCTAssertEqual(
            AppleSpeechAnalyzerBackend.requestedLocale(
                languageCode: "es",
                currentLocale: Locale(identifier: "fr_CA")
            ).identifier,
            "es"
        )
        XCTAssertEqual(
            AppleSpeechAnalyzerBackend.requestedLocale(
                languageCode: nil,
                currentLocale: Locale(identifier: "fr_CA")
            ).identifier,
            "fr_CA"
        )
    }

    func testAnalyzerBufferClipsFloatSamplesToValidPCMRange() throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )

        let buffer = try AppleSpeechAnalyzerBackend.makeAnalyzerBuffer(
            audioBuffer: [-2, -0.5, 0, 0.5, 2],
            format: format
        )
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])

        XCTAssertEqual(buffer.frameLength, 5)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: channel, count: 5)), [-1, -0.5, 0, 0.5, 1])
    }

    func testAnalyzerBufferConvertsToRequestedIntegerFormat() throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )

        let buffer = try AppleSpeechAnalyzerBackend.makeAnalyzerBuffer(
            audioBuffer: [-1, 0, 1],
            format: format
        )

        XCTAssertEqual(buffer.format.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(buffer.format.sampleRate, 16_000)
        XCTAssertEqual(buffer.format.channelCount, 1)
        XCTAssertEqual(buffer.frameLength, 3)
        XCTAssertNotNil(buffer.int16ChannelData)
    }

    func testPrepareRejectsUnsupportedLocaleWithoutFallback() async throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }

        do {
            _ = try await AppleSpeechAnalyzerBackend.prepare(
                languageCode: "zz_ZZ",
                currentLocale: Locale(identifier: "en_US"),
                supportedLocaleResolver: { _ in nil },
                progressHandler: { _ in }
            )
            XCTFail("Expected an unsupported-locale error")
        } catch let error as AppleSpeechAnalyzerError {
            guard case .unsupportedLocale("zz_ZZ") = error else {
                return XCTFail("Unexpected error: \(error.localizedDescription)")
            }
        }
    }
}
```

Add `import AVFAudio` at the top of the test file, above `import XCTest`.

- [ ] **Step 2: Run the backend tests and verify they fail**

Run:

```bash
xcodebuild test -project GhostPepper.xcodeproj -scheme GhostPepper -destination 'platform=macOS' -only-testing:GhostPepperTests/AppleSpeechAnalyzerBackendTests
```

Expected: compilation fails with `cannot find 'AppleSpeechAnalyzerBackend' in scope`.

- [ ] **Step 3: Implement the availability-gated backend**

Create `GhostPepper/Transcription/AppleSpeechAnalyzerBackend.swift` with this implementation:

```swift
import AVFAudio
import Foundation
import Speech

@MainActor
protocol SpeechAnalyzerTranscribing: AnyObject {
    func transcribe(audioBuffer: [Float]) async throws -> String?
}

@available(macOS 26.0, *)
enum AppleSpeechAnalyzerError: LocalizedError {
    case unavailable
    case unsupportedLocale(String)
    case emptyAudio
    case missingAudioFormat
    case audioBufferCreationFailed
    case audioConverterCreationFailed
    case audioConversionFailed(Error)
    case assetInstallationFailed(Error)
    case analysisFailed(Error)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Apple SpeechAnalyzer is unavailable on this Mac."
        case .unsupportedLocale(let identifier):
            "Apple SpeechAnalyzer does not support the \(identifier) locale."
        case .emptyAudio:
            "Apple SpeechAnalyzer received an empty audio buffer."
        case .missingAudioFormat:
            "Apple SpeechAnalyzer did not provide a compatible audio format."
        case .audioBufferCreationFailed:
            "Ghost Pepper could not create an audio buffer for Apple SpeechAnalyzer."
        case .audioConverterCreationFailed:
            "Ghost Pepper could not create an audio converter for Apple SpeechAnalyzer."
        case .audioConversionFailed(let error):
            "Ghost Pepper could not convert audio for Apple SpeechAnalyzer: \(error.localizedDescription)"
        case .assetInstallationFailed(let error):
            "Apple SpeechAnalyzer could not install its language assets: \(error.localizedDescription)"
        case .analysisFailed(let error):
            "Apple SpeechAnalyzer could not transcribe the recording: \(error.localizedDescription)"
        }
    }
}

@available(macOS 26.0, *)
@MainActor
final class AppleSpeechAnalyzerBackend: SpeechAnalyzerTranscribing {
    typealias ProgressHandler = @MainActor (Double?) -> Void
    typealias SupportedLocaleResolver = @MainActor (Locale) async -> Locale?

    private let locale: Locale

    private init(locale: Locale) {
        self.locale = locale
    }

    static func prepare(
        languageCode: String?,
        currentLocale: Locale = .current,
        supportedLocaleResolver: SupportedLocaleResolver? = nil,
        progressHandler: @escaping ProgressHandler
    ) async throws -> AppleSpeechAnalyzerBackend {
        guard Speech.SpeechTranscriber.isAvailable else {
            throw AppleSpeechAnalyzerError.unavailable
        }

        let requestedLocale = requestedLocale(
            languageCode: languageCode,
            currentLocale: currentLocale
        )
        let supportedLocale: Locale?
        if let supportedLocaleResolver {
            supportedLocale = await supportedLocaleResolver(requestedLocale)
        } else {
            supportedLocale = await Speech.SpeechTranscriber.supportedLocale(
                equivalentTo: requestedLocale
            )
        }
        guard let supportedLocale else {
            throw AppleSpeechAnalyzerError.unsupportedLocale(requestedLocale.identifier)
        }

        let module = Speech.SpeechTranscriber(
            locale: supportedLocale,
            preset: .transcription
        )

        do {
            if let request = try await Speech.AssetInventory.assetInstallationRequest(
                supporting: [module]
            ) {
                let observation = request.progress.observe(
                    \.fractionCompleted,
                    options: [.initial, .new]
                ) { progress, _ in
                    Task { @MainActor in
                        progressHandler(progress.fractionCompleted)
                    }
                }
                defer {
                    observation.invalidate()
                    progressHandler(nil)
                }
                try await request.downloadAndInstall()
            }
        } catch {
            throw AppleSpeechAnalyzerError.assetInstallationFailed(error)
        }

        return AppleSpeechAnalyzerBackend(locale: supportedLocale)
    }

    static func requestedLocale(
        languageCode: String?,
        currentLocale: Locale = .current
    ) -> Locale {
        guard let languageCode, languageCode.isEmpty == false else {
            return currentLocale
        }
        return Locale(identifier: languageCode)
    }

    func transcribe(audioBuffer: [Float]) async throws -> String? {
        guard audioBuffer.isEmpty == false else {
            return nil
        }

        let module = Speech.SpeechTranscriber(locale: locale, preset: .transcription)
        guard let format = await Speech.SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module]
        ) else {
            throw AppleSpeechAnalyzerError.missingAudioFormat
        }
        let buffer = try Self.makeAnalyzerBuffer(audioBuffer: audioBuffer, format: format)
        let analyzer = Speech.SpeechAnalyzer(modules: [module])
        let resultTask = Task<[String], Error> {
            var results: [String] = []
            for try await result in module.results {
                results.append(String(result.text.characters))
            }
            return results
        }
        let inputs = AsyncStream<Speech.AnalyzerInput> { continuation in
            continuation.yield(Speech.AnalyzerInput(buffer: buffer))
            continuation.finish()
        }

        do {
            if let lastSampleTime = try await analyzer.analyzeSequence(inputs) {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }

            let text = try await resultTask.value
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw AppleSpeechAnalyzerError.analysisFailed(error)
        }
    }

    static func makeAnalyzerBuffer(
        audioBuffer: [Float],
        format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard audioBuffer.isEmpty == false else {
            throw AppleSpeechAnalyzerError.emptyAudio
        }
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(audioBuffer.count)
        ), let sourceChannel = sourceBuffer.floatChannelData?[0] else {
            throw AppleSpeechAnalyzerError.audioBufferCreationFailed
        }

        let clippedSamples = audioBuffer.map { min(max($0, -1), 1) }
        sourceChannel.update(from: clippedSamples, count: clippedSamples.count)
        sourceBuffer.frameLength = AVAudioFrameCount(clippedSamples.count)

        if sourceFormat == format {
            return sourceBuffer
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: format) else {
            throw AppleSpeechAnalyzerError.audioConverterCreationFailed
        }
        let ratio = format.sampleRate / sourceFormat.sampleRate
        let frameCapacity = max(
            AVAudioFrameCount(ceil(Double(sourceBuffer.frameLength) * ratio)),
            1
        )
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCapacity
        ) else {
            throw AppleSpeechAnalyzerError.audioBufferCreationFailed
        }

        do {
            try converter.convert(to: convertedBuffer, from: sourceBuffer)
        } catch {
            throw AppleSpeechAnalyzerError.audioConversionFailed(error)
        }
        return convertedBuffer
    }
}
```

- [ ] **Step 4: Register the backend with the app target**

First confirm the planned PBX identifiers are unused:

```bash
rg '26A00000000000000000000[12]' GhostPepper.xcodeproj/project.pbxproj
```

Expected: no matches.

Add these four project entries in their matching sections:

```text
/* PBXBuildFile */
26A000000000000000000002 /* AppleSpeechAnalyzerBackend.swift in Sources */ = {isa = PBXBuildFile; fileRef = 26A000000000000000000001 /* AppleSpeechAnalyzerBackend.swift */; };

/* PBXFileReference */
26A000000000000000000001 /* AppleSpeechAnalyzerBackend.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AppleSpeechAnalyzerBackend.swift; sourceTree = "<group>"; };

/* B242BF76D6E42784C2A05EB5 Transcription group children */
26A000000000000000000001 /* AppleSpeechAnalyzerBackend.swift */,

/* 24067D7D335818724D4D6FCF app Sources files */
26A000000000000000000002 /* AppleSpeechAnalyzerBackend.swift in Sources */,
```

- [ ] **Step 5: Run backend tests and the macOS 14 compile gate**

Run:

```bash
xcodebuild test -project GhostPepper.xcodeproj -scheme GhostPepper -destination 'platform=macOS' -only-testing:GhostPepperTests/AppleSpeechAnalyzerBackendTests
xcodebuild build -project GhostPepper.xcodeproj -scheme GhostPepper -destination 'platform=macOS' MACOSX_DEPLOYMENT_TARGET=14.0 CODE_SIGNING_ALLOWED=NO
```

Expected: both commands finish successfully; the tests verify real PCM buffer behavior and the build confirms macOS 26 references remain availability-safe.

- [ ] **Step 6: Commit the backend**

```bash
git status --short
git add GhostPepper/Transcription/AppleSpeechAnalyzerBackend.swift GhostPepperTests/SpeechTranscriberTests.swift GhostPepper.xcodeproj/project.pbxproj
git commit -m "feat: add the Apple SpeechAnalyzer batch backend" -m "Resolve explicit or system locales, install missing system-managed assets with progress, convert Ghost Pepper's Float32 samples to Apple's requested PCM format, and finalize every analyzer session before returning ordered text. Keep all SpeechAnalyzer APIs isolated behind macOS 26 availability."
```

### Task 3: Route SpeechAnalyzer through ModelManager

**Files:**
- Modify: `GhostPepperTests/ModelManagerTests.swift`
- Modify: `GhostPepper/Transcription/ModelManager.swift`

**Interfaces:**
- Consumes: `SpeechAnalyzerTranscribing` and `AppleSpeechAnalyzerBackend.prepare(languageCode:progressHandler:)` from Task 2.
- Produces: `ModelManager.loadModel(name:language:)`, a prepared SpeechAnalyzer backend, locale-sensitive reload behavior, shared batch transcription routing, and system-managed cache guards.

- [ ] **Step 1: Write failing routing and reload tests**

Add these tests inside `ModelManagerTests`:

```swift
func testSpeechAnalyzerLoadAndTranscriptionUseInjectedBackend() async throws {
    guard #available(macOS 26, *) else {
        throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
    }
    let backend = StubSpeechAnalyzerBackend(result: "Ghost Pepper transcription")
    var requestedLanguages: [String?] = []
    let manager = ModelManager(
        modelName: SpeechModelCatalog.speechAnalyzer.id,
        speechAnalyzerBackendFactory: { language in
            requestedLanguages.append(language)
            return backend
        }
    )

    await manager.loadModel(language: "es")
    let result = await manager.transcribe(audioBuffer: [0.25, -0.25])

    XCTAssertEqual(manager.state, .ready)
    XCTAssertEqual(requestedLanguages.count, 1)
    XCTAssertEqual(requestedLanguages[0], "es")
    XCTAssertEqual(result, "Ghost Pepper transcription")
    XCTAssertEqual(backend.receivedAudioBuffers, [[0.25, -0.25]])
}

func testSpeechAnalyzerReloadsOnlyWhenPreparedLanguageChanges() async throws {
    guard #available(macOS 26, *) else {
        throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
    }
    var requestedLanguages: [String?] = []
    let manager = ModelManager(
        modelName: SpeechModelCatalog.speechAnalyzer.id,
        speechAnalyzerBackendFactory: { language in
            requestedLanguages.append(language)
            return StubSpeechAnalyzerBackend(result: nil)
        }
    )

    await manager.loadModel(language: "en")
    await manager.loadModel(language: "en")
    await manager.loadModel(language: "es")

    XCTAssertEqual(requestedLanguages.count, 2)
    XCTAssertEqual(requestedLanguages[0], "en")
    XCTAssertEqual(requestedLanguages[1], "es")
    XCTAssertEqual(manager.state, .ready)
}

func testSpeechAnalyzerLoadFailureUsesExistingErrorState() async throws {
    guard #available(macOS 26, *) else {
        throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
    }
    struct AssetFailure: Error {}
    let manager = ModelManager(
        modelName: SpeechModelCatalog.speechAnalyzer.id,
        speechAnalyzerBackendFactory: { _ in throw AssetFailure() }
    )

    await manager.loadModel(language: "es")

    XCTAssertEqual(manager.state, .error)
    XCTAssertNotNil(manager.error)
}

func testDeletingSystemManagedSpeechAnalyzerDoesNothing() async throws {
    guard #available(macOS 26, *) else {
        throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
    }
    let manager = ModelManager(
        modelName: SpeechModelCatalog.speechAnalyzer.id,
        speechAnalyzerBackendFactory: { _ in
            StubSpeechAnalyzerBackend(result: nil)
        }
    )
    await manager.loadModel()

    manager.deleteCachedModel(SpeechModelCatalog.speechAnalyzer)

    XCTAssertEqual(manager.state, .ready)
    XCTAssertEqual(manager.modelName, SpeechModelCatalog.speechAnalyzer.id)
}
```

Add this test double after the test class:

```swift
@MainActor
private final class StubSpeechAnalyzerBackend: SpeechAnalyzerTranscribing {
    let result: String?
    private(set) var receivedAudioBuffers: [[Float]] = []

    init(result: String?) {
        self.result = result
    }

    func transcribe(audioBuffer: [Float]) async throws -> String? {
        receivedAudioBuffers.append(audioBuffer)
        return result
    }
}
```

- [ ] **Step 2: Run the ModelManager tests and verify the new API is missing**

Run:

```bash
xcodebuild test -project GhostPepper.xcodeproj -scheme GhostPepper -destination 'platform=macOS' -only-testing:GhostPepperTests/ModelManagerTests
```

Expected: compilation fails because `speechAnalyzerBackendFactory` and `loadModel(language:)` do not exist.

- [ ] **Step 3: Add the testable factory and language-sensitive load state**

Add the factory type, retained backend, and language key near ModelManager's existing typealiases and backend storage:

```swift
typealias SpeechAnalyzerBackendFactory = @MainActor (
    _ language: String?
) async throws -> any SpeechAnalyzerTranscribing

private var speechAnalyzerBackend: (any SpeechAnalyzerTranscribing)?
private var loadedSpeechAnalyzerLanguage: String?
private let speechAnalyzerBackendFactory: SpeechAnalyzerBackendFactory?
```

Extend the initializer and store the factory:

```swift
init(
    modelName: String = SpeechModelCatalog.defaultModelID,
    modelLoadOverride: ModelLoadOverride? = nil,
    loadRetryDelayOverride: RetryDelayOverride? = nil,
    speechAnalyzerBackendFactory: SpeechAnalyzerBackendFactory? = nil
) {
    self.modelName = modelName
    self.modelLoadOverride = modelLoadOverride
    self.loadRetryDelayOverride = loadRetryDelayOverride
    self.speechAnalyzerBackendFactory = speechAnalyzerBackendFactory
}
```

Change the load signature and ready-state handling so a selected Apple model reloads only for a different language:

```swift
func loadModel(name: String? = nil, language: String? = nil) async {
    let requestedName = name ?? modelName
    guard let requestedModel = SpeechModelCatalog.model(named: requestedName) else {
        let missingModelError = NSError(
            domain: "GhostPepper.ModelManager",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "Unknown speech model \(requestedName)"]
        )
        error = missingModelError
        state = .error
        return
    }

    let speechAnalyzerLanguageChanged = requestedModel.backend == .speechAnalyzer
        && speechAnalyzerBackend != nil
        && loadedSpeechAnalyzerLanguage != language
    if state == .ready && (requestedName != modelName || speechAnalyzerLanguageChanged) {
        resetLoadedModels()
    } else if state == .ready {
        return
    }
    modelName = requestedName

    guard state == .idle || state == .error else { return }

    state = .loading
    error = nil
    debugLogger?(.model, "Loading speech model \(modelName).")

    do {
        do {
            try await loadRequestedModel(requestedModel, language: language)
        } catch {
            guard Self.isRetryableLoadError(error) else {
                throw error
            }

            debugLogger?(.model, "Speech model \(modelName) load timed out. Retrying once.")
            clearLoadedModelInstances()
            await retryLoadDelay()
            try await loadRequestedModel(requestedModel, language: language)
        }
        state = .ready
        debugLogger?(.model, "Speech model \(modelName) loaded successfully.")
    } catch {
        self.error = error
        state = .error
        debugLogger?(.model, "Speech model \(modelName) failed to load: \(error.localizedDescription)")
    }
}
```

Change `loadRequestedModel` to accept the language and add the Apple case:

```swift
private func loadRequestedModel(
    _ requestedModel: SpeechModelDescriptor,
    language: String?
) async throws {
    if let modelLoadOverride {
        try await modelLoadOverride(requestedModel)
        return
    }

    switch requestedModel.backend {
    case .whisperKit:
        try await loadWhisperModel(named: requestedModel.name)
    case .fluidAudio:
        switch requestedModel.fluidAudioVariant {
        case .qwen3AsrInt8:
            if #available(macOS 15, iOS 18, *) {
                try await loadQwen3AsrModel(requestedModel)
            } else {
                throw NSError(
                    domain: "GhostPepper.ModelManager",
                    code: 501,
                    userInfo: [NSLocalizedDescriptionKey: "Qwen3-ASR requires macOS 15 or later."]
                )
            }
        case .parakeetV3, .none:
            try await loadFluidAudioModel(requestedModel)
        }
    case .speechAnalyzer:
        try await loadSpeechAnalyzer(language: language)
    }
}
```

Add the loader beside the existing backend loaders:

```swift
private func loadSpeechAnalyzer(language: String?) async throws {
    let backend: any SpeechAnalyzerTranscribing
    if let speechAnalyzerBackendFactory {
        backend = try await speechAnalyzerBackendFactory(language)
    } else if #available(macOS 26.0, *) {
        backend = try await AppleSpeechAnalyzerBackend.prepare(
            languageCode: language,
            progressHandler: { [weak self] progress in
                self?.downloadProgress = progress
            }
        )
    } else {
        throw NSError(
            domain: "GhostPepper.ModelManager",
            code: 501,
            userInfo: [NSLocalizedDescriptionKey: "Apple SpeechAnalyzer requires macOS 26 or later."]
        )
    }

    speechAnalyzerBackend = backend
    loadedSpeechAnalyzerLanguage = language
    downloadProgress = nil
}
```

- [ ] **Step 4: Add transcription, reset, and cache branches**

Add this case to `transcribe(audioBuffer:language:)`:

```swift
case .speechAnalyzer:
    guard let speechAnalyzerBackend else { return nil }
    return try await speechAnalyzerBackend.transcribe(audioBuffer: audioBuffer)
```

Add these resets to `clearLoadedModelInstances()`:

```swift
speechAnalyzerBackend = nil
loadedSpeechAnalyzerLanguage = nil
```

Guard deletion at the start of `deleteCachedModel(_:)`:

```swift
guard model.isSystemManaged == false else {
    return
}
```

Add `.speechAnalyzer` to both cache switches:

```swift
case .speechAnalyzer:
    break
```

and:

```swift
case .speechAnalyzer:
    return true
```

The `true` cache value means the option is always selectable; it does not claim that every locale asset is installed. Preparation remains the source of truth for the selected locale.

- [ ] **Step 5: Run ModelManager and speech catalog tests**

Run:

```bash
xcodebuild test -project GhostPepper.xcodeproj -scheme GhostPepper -destination 'platform=macOS' -only-testing:GhostPepperTests/ModelManagerTests -only-testing:GhostPepperTests/SpeechTranscriberTests -only-testing:GhostPepperTests/AppleSpeechAnalyzerBackendTests
```

Expected: all selected tests pass, including the no-op deletion and language reload contracts.

- [ ] **Step 6: Commit routing**

```bash
git status --short
git add GhostPepper/Transcription/ModelManager.swift GhostPepperTests/ModelManagerTests.swift
git commit -m "feat: route SpeechAnalyzer through ModelManager" -m "Prepare the selected Apple locale, expose AssetInventory progress through existing model state, route shared batch transcription to the prepared backend, reload only when the selected Apple language changes, and prevent app-owned deletion of system assets."
```

### Task 4: Forward language selection through AppState and Settings

**Files:**
- Modify: `GhostPepperTests/GhostPepperTests.swift`
- Modify: `GhostPepper/AppState.swift`
- Modify: `GhostPepper/UI/SettingsWindow.swift`
- Modify: `GhostPepper/Info.plist`

**Interfaces:**
- Consumes: `ModelManager.loadModel(name:language:)` and `SpeechModelDescriptor.automaticLanguageLabel`.
- Produces: language-aware app loading, `reloadSpeechAnalyzerForPreferredLanguageIfNeeded()`, model-specific automatic-language copy, and the required Speech framework usage description.

- [ ] **Step 1: Write failing AppState language tests**

Add these tests inside `GhostPepperTests`:

```swift
func testAppStatePassesPreferredLanguageWhenLoadingSpeechAnalyzer() async throws {
    guard #available(macOS 26, *) else {
        throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
    }
    var requestedLanguages: [String?] = []
    let manager = ModelManager(
        modelName: SpeechModelCatalog.speechAnalyzer.id,
        speechAnalyzerBackendFactory: { language in
            requestedLanguages.append(language)
            return AppStateSpeechAnalyzerStub()
        }
    )
    let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
    defaults.removePersistentDomain(forName: #function)
    let previousLanguage = UserDefaults.standard.object(forKey: "preferredLanguage")
    defer {
        if let previousLanguage {
            UserDefaults.standard.set(previousLanguage, forKey: "preferredLanguage")
        } else {
            UserDefaults.standard.removeObject(forKey: "preferredLanguage")
        }
    }
    let appState = AppState(
        hotkeyMonitor: FakeHotkeyMonitor(),
        chordBindingStore: ChordBindingStore(defaults: defaults),
        cleanupSettingsDefaults: defaults,
        modelManager: manager
    )

    appState.preferredLanguage = "es"
    await appState.loadSpeechModel(name: SpeechModelCatalog.speechAnalyzer.id)
    appState.preferredLanguage = "auto"
    await appState.loadSpeechModel(name: SpeechModelCatalog.speechAnalyzer.id)

    XCTAssertEqual(requestedLanguages.count, 2)
    XCTAssertEqual(requestedLanguages[0], "es")
    XCTAssertNil(requestedLanguages[1])
}

func testAppStateRepreparesForLanguageChangesOnlyWhenSpeechAnalyzerIsSelected() async throws {
    guard #available(macOS 26, *) else {
        throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
    }
    var requestedLanguages: [String?] = []
    let manager = ModelManager(
        modelName: SpeechModelCatalog.speechAnalyzer.id,
        speechAnalyzerBackendFactory: { language in
            requestedLanguages.append(language)
            return AppStateSpeechAnalyzerStub()
        }
    )
    let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
    defaults.removePersistentDomain(forName: #function)
    let previousLanguage = UserDefaults.standard.object(forKey: "preferredLanguage")
    let previousModel = UserDefaults.standard.object(forKey: "speechModel")
    defer {
        if let previousLanguage {
            UserDefaults.standard.set(previousLanguage, forKey: "preferredLanguage")
        } else {
            UserDefaults.standard.removeObject(forKey: "preferredLanguage")
        }
        if let previousModel {
            UserDefaults.standard.set(previousModel, forKey: "speechModel")
        } else {
            UserDefaults.standard.removeObject(forKey: "speechModel")
        }
    }
    let appState = AppState(
        hotkeyMonitor: FakeHotkeyMonitor(),
        chordBindingStore: ChordBindingStore(defaults: defaults),
        cleanupSettingsDefaults: defaults,
        modelManager: manager
    )
    appState.preferredLanguage = "fr"

    appState.speechModel = SpeechModelCatalog.whisperSmallEnglish.id
    await appState.reloadSpeechAnalyzerForPreferredLanguageIfNeeded()
    XCTAssertTrue(requestedLanguages.isEmpty)

    appState.speechModel = SpeechModelCatalog.speechAnalyzer.id
    await appState.reloadSpeechAnalyzerForPreferredLanguageIfNeeded()
    XCTAssertEqual(requestedLanguages.count, 1)
    XCTAssertEqual(requestedLanguages[0], "fr")
}
```

Add this test double near the file's other private fakes:

```swift
@MainActor
private final class AppStateSpeechAnalyzerStub: SpeechAnalyzerTranscribing {
    func transcribe(audioBuffer: [Float]) async throws -> String? {
        nil
    }
}
```

- [ ] **Step 2: Run the AppState tests and verify dependency/language forwarding is absent**

Run:

```bash
xcodebuild test -project GhostPepper.xcodeproj -scheme GhostPepper -destination 'platform=macOS' -only-testing:GhostPepperTests/GhostPepperTests/testAppStatePassesPreferredLanguageWhenLoadingSpeechAnalyzer -only-testing:GhostPepperTests/GhostPepperTests/testAppStateRepreparesForLanguageChangesOnlyWhenSpeechAnalyzerIsSelected
```

Expected: compilation fails because AppState does not accept a `modelManager` and does not define the reload method.

- [ ] **Step 3: Inject ModelManager and forward the preferred language**

Change AppState's property from an inline initializer to an injected property:

```swift
let modelManager: ModelManager
```

Add this parameter to the existing initializer after `cleanupSettingsDefaults`:

```swift
modelManager: ModelManager = ModelManager(),
```

Store it before constructing `SpeechTranscriber`:

```swift
self.modelManager = modelManager
```

Replace `loadSpeechModel(name:)` and add the conditional reload method:

```swift
func loadSpeechModel(name: String) async {
    let language = preferredLanguage == "auto" ? nil : preferredLanguage
    await modelManager.loadModel(name: name, language: language)
    let nextPresentation = Self.nextSpeechModelPresentation(
        managerState: modelManager.state,
        managerError: modelManager.error,
        currentStatus: status,
        currentErrorMessage: errorMessage
    )
    status = nextPresentation.status
    errorMessage = nextPresentation.errorMessage
}

func reloadSpeechAnalyzerForPreferredLanguageIfNeeded() async {
    guard SpeechModelCatalog.model(named: speechModel)?.backend == .speechAnalyzer else {
        return
    }
    await loadSpeechModel(name: speechModel)
}
```

- [ ] **Step 4: Wire Settings language copy and repreparation**

Replace the first language picker row in `SettingsWindow.modelsSection` with:

```swift
Text(
    SpeechModelCatalog.model(named: appState.speechModel)?.automaticLanguageLabel
        ?? "Auto-detect"
).tag("auto")
```

Add this modifier after the language picker's frame modifier:

```swift
.onChange(of: appState.preferredLanguage) { _, _ in
    Task {
        await appState.reloadSpeechAnalyzerForPreferredLanguageIfNeeded()
    }
}
```

Keep the remaining explicit language tags unchanged. The Transcription Lab model picker already reads `ModelManager.availableModels`; its loader calls `AppState.loadSpeechModel`, so it inherits the prepared locale without a second path.

- [ ] **Step 5: Add the Speech framework usage string**

Add this key after `NSMicrophoneUsageDescription` in `GhostPepper/Info.plist`:

```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>Ghost Pepper uses on-device speech recognition to transcribe your recordings.</string>
```

Do not add an `SFSpeechRecognizer.requestAuthorization` call.

- [ ] **Step 6: Run focused tests and validate the plist**

Run:

```bash
xcodebuild test -project GhostPepper.xcodeproj -scheme GhostPepper -destination 'platform=macOS' -only-testing:GhostPepperTests/GhostPepperTests/testAppStatePassesPreferredLanguageWhenLoadingSpeechAnalyzer -only-testing:GhostPepperTests/GhostPepperTests/testAppStateRepreparesForLanguageChangesOnlyWhenSpeechAnalyzerIsSelected
plutil -extract NSSpeechRecognitionUsageDescription raw GhostPepper/Info.plist
```

Expected: tests pass and `plutil` prints `Ghost Pepper uses on-device speech recognition to transcribe your recordings.`

- [ ] **Step 7: Commit AppState and Settings integration**

```bash
git status --short
git add GhostPepper/AppState.swift GhostPepper/UI/SettingsWindow.swift GhostPepper/Info.plist GhostPepperTests/GhostPepperTests.swift
git commit -m "feat: prepare SpeechAnalyzer for the selected language" -m "Pass explicit languages or the system-locale choice into SpeechAnalyzer model loading, reprepare only the selected Apple backend when language changes, display accurate automatic-language copy, and add the on-device Speech framework usage description without requesting legacy server authorization."
```

### Task 5: Represent system-managed assets across model inventory UIs

**Files:**
- Modify: `GhostPepperTests/RuntimeModelInventoryTests.swift`
- Modify: `GhostPepper/ModelInventory.swift`
- Modify: `GhostPepper/UI/ModelInventoryViews.swift`
- Modify: `GhostPepper/UI/ModelsSidebarView.swift`
- Modify: `GhostPepper/UI/OnboardingWindow.swift`

**Interfaces:**
- Consumes: `SpeechModelDescriptor.isSystemManaged`, `ModelManager.downloadProgress`, and the existing inventory row builders.
- Produces: `.systemManaged`, `allowsManualDownload`, and `allowsDeletion`; both model UIs consume these contracts instead of inferring asset ownership from cache presence.

- [ ] **Step 1: Write failing inventory behavior tests**

Add these tests to `RuntimeModelInventoryTests`:

```swift
func testSpeechAnalyzerRowIsSystemManagedWithoutManualActions() throws {
    guard #available(macOS 26, *) else {
        throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
    }
    let rows = RuntimeModelInventory.rows(
        selectedSpeechModelName: SpeechModelCatalog.speechAnalyzer.id,
        activeSpeechModelName: SpeechModelCatalog.speechAnalyzer.id,
        speechModelState: .ready,
        speechDownloadProgress: nil,
        cachedSpeechModelNames: [],
        cleanupState: .idle,
        selectedCleanupModelKind: .qwen35_2b_q4_k_m,
        cachedCleanupKinds: []
    )
    let row = try XCTUnwrap(rows.first { $0.id == SpeechModelCatalog.speechAnalyzer.id })

    XCTAssertEqual(row.name, "Apple SpeechAnalyzer")
    XCTAssertEqual(row.sizeDescription, "Managed by macOS")
    XCTAssertEqual(row.status, .systemManaged)
    XCTAssertFalse(row.allowsManualDownload)
    XCTAssertFalse(row.allowsDeletion)
}

func testSpeechAnalyzerRowShowsAssetDownloadProgressWithoutManualActions() throws {
    guard #available(macOS 26, *) else {
        throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
    }
    let rows = RuntimeModelInventory.rows(
        selectedSpeechModelName: SpeechModelCatalog.speechAnalyzer.id,
        activeSpeechModelName: SpeechModelCatalog.speechAnalyzer.id,
        speechModelState: .loading,
        speechDownloadProgress: 0.35,
        cachedSpeechModelNames: [SpeechModelCatalog.speechAnalyzer.id],
        cleanupState: .idle,
        selectedCleanupModelKind: .qwen35_2b_q4_k_m,
        cachedCleanupKinds: []
    )
    let row = try XCTUnwrap(rows.first { $0.id == SpeechModelCatalog.speechAnalyzer.id })

    XCTAssertEqual(row.status, .downloading(progress: 0.35))
    XCTAssertFalse(row.allowsManualDownload)
    XCTAssertFalse(row.allowsDeletion)
    XCTAssertEqual(
        RuntimeModelInventory.activeDownloadText(rows: rows),
        "Downloading Apple SpeechAnalyzer (35%)..."
    )
}
```

- [ ] **Step 2: Run inventory tests and verify the status/action contract is absent**

Run:

```bash
xcodebuild test -project GhostPepper.xcodeproj -scheme GhostPepper -destination 'platform=macOS' -only-testing:GhostPepperTests/RuntimeModelInventoryTests
```

Expected: compilation fails because `.systemManaged`, `allowsManualDownload`, and `allowsDeletion` do not exist.

- [ ] **Step 3: Add system-managed status and action capabilities**

Extend the status and row definitions in `ModelInventory.swift`:

```swift
enum RuntimeModelStatus: Equatable {
    case notLoaded
    case loading
    case downloading(progress: Double?)
    case loaded
    case systemManaged
}

struct RuntimeModelRow: Identifiable, Equatable {
    let id: String
    let name: String
    let sizeDescription: String
    let isSelected: Bool
    let status: RuntimeModelStatus
    let allowsManualDownload: Bool
    let allowsDeletion: Bool
}
```

Build speech rows with descriptor ownership:

```swift
RuntimeModelRow(
    id: model.name,
    name: model.statusName,
    sizeDescription: model.sizeDescription,
    isSelected: model.name == selectedSpeechModelName,
    status: statusForSpeechModel(
        model: model,
        activeSpeechModelName: activeSpeechModelName,
        speechModelState: speechModelState,
        speechDownloadProgress: speechDownloadProgress,
        cachedSpeechModelNames: cachedSpeechModelNames
    ),
    allowsManualDownload: model.isSystemManaged == false,
    allowsDeletion: model.isSystemManaged == false
)
```

Add these fields to cleanup row construction:

```swift
allowsManualDownload: true,
allowsDeletion: true
```

Replace `statusForSpeechModel` with:

```swift
private static func statusForSpeechModel(
    model: SpeechModelDescriptor,
    activeSpeechModelName: String,
    speechModelState: ModelManagerState,
    speechDownloadProgress: Double?,
    cachedSpeechModelNames: Set<String>
) -> RuntimeModelStatus {
    if speechModelState == .loading && model.name == activeSpeechModelName {
        if model.isSystemManaged {
            return .downloading(progress: speechDownloadProgress)
        }
        if cachedSpeechModelNames.contains(model.name) {
            return .loading
        }
        return .downloading(progress: speechDownloadProgress)
    }

    if model.isSystemManaged {
        return .systemManaged
    }
    return cachedSpeechModelNames.contains(model.name) ? .loaded : .notLoaded
}
```

Add `.systemManaged` to `activeDownloadText`'s non-download cases:

```swift
case .loading, .loaded, .notLoaded, .systemManaged:
    return nil
```

- [ ] **Step 4: Make ModelInventoryViews consume the row capabilities**

Update both action gates:

```swift
private func canDelete(_ row: RuntimeModelRow) -> Bool {
    guard onDelete != nil, row.allowsDeletion else { return false }
    return row.status == .loaded && !row.isSelected
}

private func canDownload(_ row: RuntimeModelRow) -> Bool {
    guard onDownload != nil, row.allowsManualDownload else { return false }
    return row.status == .notLoaded
}
```

Add `systemManaged` to `RuntimeModelStatus.identityKey`:

```swift
case .systemManaged:
    return "system-managed"
```

Add this row status text:

```swift
case .systemManaged:
    return "Managed by macOS"
```

Add this status indicator branch:

```swift
case .systemManaged:
    Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
```

- [ ] **Step 5: Remove app-owned asset controls from ModelsSidebarView**

Replace the speech model's `downloaded` calculation and action closures in `localModelsSection`:

```swift
let downloaded = model.isSystemManaged || ModelManager.isCached(model)
let isActive = model.id == selectedSpeechModelID
LocalModelRow(
    title: model.pickerTitle,
    subtitle: "\(model.variantName) · \(model.sizeDescription)",
    capabilities: capabilities(for: model),
    isDownloaded: downloaded,
    isActive: isActive,
    progress: speechRowProgress(for: model, downloaded: downloaded),
    onDownload: (!model.isSystemManaged && !downloaded)
        ? { onDownloadSpeechModel(model.id) }
        : nil,
    onDelete: (!model.isSystemManaged && downloaded && !isActive)
        ? { modelManager.deleteCachedModel(model) }
        : nil
)
```

Change `downloadedSpeechModels` so the system model is available before any locale-specific download:

```swift
private var downloadedSpeechModels: [SpeechModelDescriptor] {
    SpeechModelCatalog.availableModels.filter {
        $0.isSystemManaged || ModelManager.isCached($0)
    }
}
```

Add this modifier to the speech-to-text picker so choosing any usable model calls the existing AppState loader; this is what initiates a missing SpeechAnalyzer locale download from the sidebar:

```swift
.onChange(of: selectedSpeechModelID) { _, modelID in
    onDownloadSpeechModel(modelID)
}
```

The callback already persists the selected ID and calls `AppState.loadSpeechModel`, so no second model-loading path is introduced.

Replace `speechRowProgress` so a selected system model displays AssetInventory progress even though it is usable without an app-owned cache:

```swift
private func speechRowProgress(
    for model: SpeechModelDescriptor,
    downloaded: Bool
) -> RowProgress? {
    guard modelManager.modelName == model.id else { return nil }
    switch modelManager.state {
    case .loading:
        if model.isSystemManaged {
            return .downloading(modelManager.downloadProgress)
        }
        return downloaded ? .loading : .downloading(modelManager.downloadProgress)
    case .idle, .ready, .error:
        return nil
    }
}
```

- [ ] **Step 6: Handle the system-managed status in onboarding**

Add this branch to `OnboardingModelRow.statusIndicator` in `OnboardingWindow.swift`:

```swift
case .systemManaged:
    Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .font(.caption)
```

Add this branch to `OnboardingModelRow.statusText`:

```swift
case .systemManaged: "Managed by macOS"
```

- [ ] **Step 7: Run inventory, catalog, and ModelManager tests**

Run:

```bash
xcodebuild test -project GhostPepper.xcodeproj -scheme GhostPepper -destination 'platform=macOS' -only-testing:GhostPepperTests/RuntimeModelInventoryTests -only-testing:GhostPepperTests/SpeechTranscriberTests -only-testing:GhostPepperTests/ModelManagerTests
```

Expected: all selected tests pass; SpeechAnalyzer is system-managed at rest and still shows progress while selection installs a locale.

- [ ] **Step 8: Commit inventory behavior**

```bash
git status --short
git add GhostPepper/ModelInventory.swift GhostPepper/UI/ModelInventoryViews.swift GhostPepper/UI/ModelsSidebarView.swift GhostPepper/UI/OnboardingWindow.swift GhostPepperTests/RuntimeModelInventoryTests.swift
git commit -m "feat: show SpeechAnalyzer as system managed" -m "Represent Apple speech assets independently from app-owned caches, suppress manual download and deletion controls in both model surfaces, keep the option selectable, and continue to expose selection-triggered AssetInventory progress."
```

### Task 6: Verify automated and live macOS 26 behavior

**Files:**
- Verify: `GhostPepper.xcodeproj/project.pbxproj`
- Verify: `GhostPepper/Info.plist`
- Verify: the built Ghost Pepper app on macOS 26

**Interfaces:**
- Consumes: the complete implementation from Tasks 1-5.
- Produces: evidence that older deployment builds, automated behavior, asset downloads, dictation, meetings, Transcription Lab, and persistence all work end to end.

- [ ] **Step 1: Run formatting and project-integrity checks**

```bash
git diff --check
plutil -lint GhostPepper/Info.plist
xcodebuild -project GhostPepper.xcodeproj -list
```

Expected: no whitespace errors, the plist reports `OK`, and Xcode lists the `GhostPepper` scheme.

- [ ] **Step 2: Run the complete automated suite**

```bash
xcodebuild test -project GhostPepper.xcodeproj -scheme GhostPepper -destination 'platform=macOS'
```

Expected: `** TEST SUCCEEDED **` with no skipped SpeechAnalyzer tests on the macOS 26 development machine.

- [ ] **Step 3: Build with the unchanged deployment floor**

```bash
xcodebuild build -project GhostPepper.xcodeproj -scheme GhostPepper -destination 'platform=macOS' MACOSX_DEPLOYMENT_TARGET=14.0 CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **`; `git diff -- GhostPepper.xcodeproj/project.pbxproj` shows no change to `MACOSX_DEPLOYMENT_TARGET = 14.0`.

- [ ] **Step 4: Build a runnable app and verify a missing asset download**

```bash
DERIVED_DATA=$(mktemp -d /tmp/GhostPepper-SpeechAnalyzer.XXXXXX)
xcodebuild build -project GhostPepper.xcodeproj -scheme GhostPepper -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA"
open "$DERIVED_DATA/Build/Products/Debug/GhostPepper.app"
```

List supported locales whose assets are not currently installed:

```bash
swift -e 'import Foundation; import Speech; if #available(macOS 26, *) { Task { let supported = await Speech.SpeechTranscriber.supportedLocales; let installed = Set(await Speech.SpeechTranscriber.installedLocales.map(\.identifier)); print(supported.map(\.identifier).filter { !installed.contains($0) }.sorted().joined(separator: "\n")); exit(0) }; RunLoop.main.run() }'
```

In Settings → Models:

1. Select `Apple SpeechAnalyzer (System model — Managed by macOS)`.
2. Choose one locale printed by the diagnostic command; use Spanish if `es_ES` is listed.
3. Confirm the active progress text advances while `AssetInventory` downloads the locale.
4. Confirm the row returns to `Managed by macOS` with no cloud-download or trash control.

If the diagnostic prints no locale, record that every supported locale is already installed and verify the installed-asset path without releasing system assets.

Expected: the selection-triggered download completes and the model reaches the ready state.

- [ ] **Step 5: Verify real transcription through every shared batch consumer**

Use a fixed spoken phrase such as `Ghost Pepper transcription test` and verify:

1. Push-to-talk dictation returns the phrase only after recording stops.
2. A meeting recording produces chunk transcripts with Apple SpeechAnalyzer selected.
3. A saved Transcription Lab recording reruns with `Apple SpeechAnalyzer` selected and produces a non-empty transcript.
4. An unsupported explicit locale produces the existing visible model error and does not return a Whisper transcript.

Expected: all three supported flows use the Apple backend; the unsupported locale fails without fallback.

- [ ] **Step 6: Verify persistence and final repository state**

Quit and reopen Ghost Pepper, then confirm Apple SpeechAnalyzer remains selected and a second dictation works without repeating an already completed locale download.

Run:

```bash
git status --short --branch
git log --oneline --decorate -7
```

Expected: the feature branch contains the design, plan, and focused implementation commits; there are no uncommitted source changes.
