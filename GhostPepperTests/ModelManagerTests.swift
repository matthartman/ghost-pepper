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
}
