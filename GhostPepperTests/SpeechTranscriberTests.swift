import AVFAudio
import XCTest
@testable import GhostPepper

@MainActor
final class SpeechTranscriberTests: XCTestCase {

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

    func testFluidAudioSpeechModelsSupportSpeakerFiltering() {
        XCTAssertFalse(SpeechModelCatalog.whisperTiny.supportsSpeakerFiltering)
        XCTAssertFalse(SpeechModelCatalog.whisperSmallEnglish.supportsSpeakerFiltering)
        XCTAssertFalse(SpeechModelCatalog.whisperSmallMultilingual.supportsSpeakerFiltering)
        XCTAssertTrue(SpeechModelCatalog.parakeetV3.supportsSpeakerFiltering)
        XCTAssertTrue(SpeechModelCatalog.qwen3AsrInt8.supportsSpeakerFiltering)
    }

    func testQwen3AsrInt8Descriptor() {
        let model = SpeechModelCatalog.qwen3AsrInt8
        XCTAssertEqual(model.name, "fluid_qwen3-asr-0.6b-int8")
        XCTAssertEqual(model.backend, .fluidAudio)
        XCTAssertEqual(model.fluidAudioVariant, .qwen3AsrInt8)
        XCTAssertTrue(model.pickerLabel.contains("Qwen3-ASR 0.6B"))
        XCTAssertTrue(model.pickerLabel.contains("int8"))
        XCTAssertTrue(model.pickerLabel.contains("~900 MB"))
    }

    func testQwen3ModelLookupIsAvailableOnSupportedOS() {
        if #available(macOS 15, iOS 18, *) {
            XCTAssertNotNil(SpeechModelCatalog.model(named: "fluid_qwen3-asr-0.6b-int8"))
        } else {
            XCTAssertNil(SpeechModelCatalog.model(named: "fluid_qwen3-asr-0.6b-int8"))
        }
    }

    // MARK: - ModelManager Tests

    func testModelManagerInitialState() {
        let manager = ModelManager()
        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(manager.isReady)
        XCTAssertNil(manager.whisperKit)
        XCTAssertNil(manager.error)
    }

    func testModelManagerDefaultModelName() {
        let manager = ModelManager()
        XCTAssertEqual(manager.modelName, "openai_whisper-small.en")
    }

    func testModelManagerCustomModelName() {
        let manager = ModelManager(modelName: "openai_whisper-tiny.en")
        XCTAssertEqual(manager.modelName, "openai_whisper-tiny.en")
    }

    func testModelManagerStateEnum() {
        // Verify all states are distinct
        let states: [ModelManagerState] = [.idle, .loading, .ready, .error]
        for (i, a) in states.enumerated() {
            for (j, b) in states.enumerated() {
                if i == j {
                    XCTAssertEqual(a, b)
                } else {
                    XCTAssertNotEqual(a, b)
                }
            }
        }
    }

    // MARK: - SpeechTranscriber Tests

    func testTranscriberReportsNotReadyBeforeModelLoad() {
        let manager = ModelManager()
        let transcriber = SpeechTranscriber(modelManager: manager)
        XCTAssertFalse(transcriber.isReady)
    }

    func testTranscriberEmptyAudioReturnsNil() async {
        let manager = ModelManager()
        let transcriber = SpeechTranscriber(modelManager: manager)
        let result = await transcriber.transcribe(audioBuffer: [])
        XCTAssertNil(result, "Empty audio buffer should return nil")
    }

    func testTranscriberReturnsNilWhenModelNotLoaded() async {
        let manager = ModelManager()
        let transcriber = SpeechTranscriber(modelManager: manager)
        // Non-empty buffer but model not loaded should return nil
        let silence = [Float](repeating: 0.0, count: 16000)
        let result = await transcriber.transcribe(audioBuffer: silence)
        XCTAssertNil(result, "Should return nil when model is not loaded")
    }

    // MARK: - Qwen3-ASR ModelManager Tests

    func testModelManagerLoadsQwen3AsrModelThroughOverride() async throws {
        guard #available(macOS 15, iOS 18, *) else {
            throw XCTSkip("Qwen3-ASR requires macOS 15 or later.")
        }

        var loadedDescriptors: [SpeechModelDescriptor] = []
        let manager = ModelManager(
            modelName: "fluid_qwen3-asr-0.6b-int8",
            modelLoadOverride: { descriptor in
                loadedDescriptors.append(descriptor)
            },
            loadRetryDelayOverride: {}
        )

        await manager.loadModel()

        XCTAssertEqual(manager.state, .ready)
        XCTAssertNil(manager.error)
        XCTAssertEqual(loadedDescriptors.count, 1)
        XCTAssertEqual(loadedDescriptors.first?.name, "fluid_qwen3-asr-0.6b-int8")
        XCTAssertEqual(loadedDescriptors.first?.fluidAudioVariant, .qwen3AsrInt8)
    }

    func testModelManagerSurfacesQwen3LoadFailure() async throws {
        guard #available(macOS 15, iOS 18, *) else {
            throw XCTSkip("Qwen3-ASR requires macOS 15 or later.")
        }

        struct DownloadFailed: Error {}
        let manager = ModelManager(
            modelName: "fluid_qwen3-asr-0.6b-int8",
            modelLoadOverride: { _ in throw DownloadFailed() },
            loadRetryDelayOverride: {}
        )

        await manager.loadModel()

        XCTAssertEqual(manager.state, .error)
        XCTAssertNotNil(manager.error)
    }

    func testModelManagerSwitchesBetweenWhisperAndQwen3() async throws {
        guard #available(macOS 15, iOS 18, *) else {
            throw XCTSkip("Qwen3-ASR requires macOS 15 or later.")
        }

        var loadedNames: [String] = []
        let manager = ModelManager(
            modelName: "openai_whisper-small.en",
            modelLoadOverride: { descriptor in
                loadedNames.append(descriptor.name)
            },
            loadRetryDelayOverride: {}
        )

        await manager.loadModel()
        XCTAssertEqual(manager.state, .ready)

        await manager.loadModel(name: "fluid_qwen3-asr-0.6b-int8")

        XCTAssertEqual(manager.state, .ready)
        XCTAssertEqual(manager.modelName, "fluid_qwen3-asr-0.6b-int8")
        XCTAssertEqual(loadedNames, [
            "openai_whisper-small.en",
            "fluid_qwen3-asr-0.6b-int8",
        ])
    }
}

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

    func testAnalyzerBufferSanitizesNonFiniteFloatSamples() throws {
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
            audioBuffer: [.nan, .infinity, -.infinity],
            format: format
        )
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])

        XCTAssertEqual(
            Array(UnsafeBufferPointer(start: channel, count: 3)),
            [0, 0, 0]
        )
    }

    func testAnalyzerResultTextConcatenatesFragmentsWithoutInsertingSpaces() throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }

        XCTAssertEqual(
            AppleSpeechAnalyzerBackend.transcriptText(
                from: ["Hello", ",", " world", "."]
            ),
            "Hello, world."
        )
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
        let channel = try XCTUnwrap(buffer.int16ChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: channel, count: 3))
        XCTAssertLessThanOrEqual(abs(Int(samples[0]) - Int(Int16.min)), 1)
        XCTAssertEqual(samples[1], 0)
        XCTAssertLessThanOrEqual(abs(Int(samples[2]) - Int(Int16.max)), 1)
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
