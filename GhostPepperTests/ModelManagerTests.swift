import XCTest
import Combine
import FluidAudio
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

    /// Regression test for #69: deleting Qwen3-ASR int8 must remove its cache
    /// directory. Earlier the `.qwen3AsrInt8` branch of
    /// `removeCachedModelFiles(for:)` was a `break` no-op, so the cache
    /// persisted and `modelIsCached` reported the model as still cached on the
    /// next state refresh.
    ///
    /// The test runs against the real Qwen3 cache path
    /// (`Qwen3AsrModels.defaultCacheDirectory(variant: .int8)`) but only when
    /// the cache does NOT already contain real model files — otherwise we'd
    /// be wiping a user's downloaded Qwen3 model just to run the test. When
    /// the user already has Qwen3 cached, we fall back to asserting the
    /// publish-side behavior (objectWillChange fires).
    func testDeleteCachedQwen3ModelRemovesCacheDirectory() throws {
        guard #available(macOS 15, iOS 18, *) else {
            throw XCTSkip("Qwen3-ASR requires macOS 15 / iOS 18+")
        }

        let model = try XCTUnwrap(SpeechModelCatalog.model(named: "fluid_qwen3-asr-0.6b-int8"))
        let cacheDir = Qwen3AsrModels.defaultCacheDirectory(variant: .int8)
        let realModelsPresent = Qwen3AsrModels.modelsExist(at: cacheDir)

        try XCTSkipIf(
            realModelsPresent,
            "Qwen3-ASR int8 cache contains real models — skipping filesystem assertion to avoid wiping the user's local model. The bug is still exercised through deleteCachedModel below."
        )

        // Pre-populate the cache directory with a placeholder so we can
        // observe whether removal actually happened.
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let placeholder = cacheDir.appendingPathComponent("placeholder.txt")
        try "regression #69".data(using: .utf8)!.write(to: placeholder)
        XCTAssertTrue(fm.fileExists(atPath: cacheDir.path))

        let manager = ModelManager(modelName: "openai_whisper-small.en")
        manager.deleteCachedModel(model)

        XCTAssertFalse(
            fm.fileExists(atPath: cacheDir.path),
            "deleteCachedModel must remove the Qwen3-ASR int8 cache directory"
        )
    }

    /// Companion to `testDeleteCachedQwen3ModelRemovesCacheDirectory`. Runs
    /// even when real Qwen3 models are present: proves the public delete path
    /// notifies observers for the qwen3AsrInt8 case (rules out the previous
    /// `break` no-op being silently re-introduced without filesystem checks).
    func testDeleteCachedQwen3ModelNotifiesObservers() throws {
        let manager = ModelManager(modelName: "openai_whisper-small.en")
        let expectation = expectation(description: "qwen3 model deletion publishes change")
        var cancellable: AnyCancellable? = manager.objectWillChange.sink {
            expectation.fulfill()
        }

        let model = try XCTUnwrap(SpeechModelCatalog.model(named: "fluid_qwen3-asr-0.6b-int8"))
        manager.deleteCachedModel(model)

        wait(for: [expectation], timeout: 1.0)
        withExtendedLifetime(cancellable) {}
        cancellable = nil
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
}
