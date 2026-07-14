import XCTest
import Combine
@testable import GhostPepper

@MainActor
final class ModelManagerTests: XCTestCase {
    func testModelManagerRetriesTimedOutSpeechModelLoadOnce() async {
        let timeoutError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "The request timed out."]
        )
        var attempts = 0
        let manager = ModelManager(
            modelName: "openai_whisper-small.en",
            modelLoadOverride: { _ in
                attempts += 1
                if attempts == 1 {
                    throw timeoutError
                }
            },
            loadRetryDelayOverride: {}
        )

        await manager.loadModel(name: "openai_whisper-small.en")

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(manager.state, .ready)
        XCTAssertNil(manager.error)
    }

    func testDeleteCachedModelNotifiesObserversForInventoryRefresh() throws {
        let manager = ModelManager(modelName: "openai_whisper-small.en")
        let expectation = expectation(description: "model manager publishes cache deletion")
        var cancellable: AnyCancellable? = manager.objectWillChange.sink {
            expectation.fulfill()
        }

        let model = try XCTUnwrap(SpeechModelCatalog.model(named: "openai_whisper-tiny.en"))
        manager.deleteCachedModel(model)

        wait(for: [expectation], timeout: 1.0)
        withExtendedLifetime(cancellable) {}
        cancellable = nil
    }

    func testDeleteCachedCurrentModelResetsReadyState() async throws {
        let manager = ModelManager(
            modelName: "openai_whisper-small.en",
            modelLoadOverride: { _ in }
        )

        await manager.loadModel(name: "openai_whisper-small.en")
        let model = try XCTUnwrap(SpeechModelCatalog.model(named: "openai_whisper-small.en"))

        manager.deleteCachedModel(model)

        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(manager.error)
    }

    func testRescueSingleSpeakerSpansUsesSpeechSegmentsWhenOnlyOneSpeakerIsDetected() {
        let originalSpans = [
            DiarizationSummary.Span(speakerID: "Speaker 0", startTime: 2.48, endTime: 4.24)
        ]
        let speechSegments = [
            DiarizationSummary.MergedSpan(startTime: 2.204, endTime: 4.5878125)
        ]

        let rescuedSpans = ModelManager.rescuedSingleSpeakerSpans(
            from: originalSpans,
            usingSpeechSegments: speechSegments
        )

        XCTAssertEqual(
            rescuedSpans,
            [
                DiarizationSummary.Span(
                    speakerID: "Speaker 0",
                    startTime: 2.204,
                    endTime: 4.5878125
                )
            ]
        )
    }

    func testRescueSingleSpeakerSpansKeepsOriginalSpansWhenMultipleSpeakersAreDetected() {
        let originalSpans = [
            DiarizationSummary.Span(speakerID: "Speaker 0", startTime: 0.4, endTime: 1.0),
            DiarizationSummary.Span(speakerID: "Speaker 1", startTime: 1.2, endTime: 1.8)
        ]
        let speechSegments = [
            DiarizationSummary.MergedSpan(startTime: 0.3, endTime: 1.9)
        ]

        let rescuedSpans = ModelManager.rescuedSingleSpeakerSpans(
            from: originalSpans,
            usingSpeechSegments: speechSegments
        )

        XCTAssertEqual(rescuedSpans, originalSpans)
    }

    func testRescueSingleSpeakerSpansKeepsOriginalSpansWhenNoSpeechSegmentsExist() {
        let originalSpans = [
            DiarizationSummary.Span(speakerID: "Speaker 0", startTime: 2.48, endTime: 4.24)
        ]

        let rescuedSpans = ModelManager.rescuedSingleSpeakerSpans(
            from: originalSpans,
            usingSpeechSegments: []
        )

        XCTAssertEqual(rescuedSpans, originalSpans)
    }

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
}

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
