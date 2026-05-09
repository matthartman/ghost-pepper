import XCTest
@testable import GhostPepper

private final class StubCleaningManager: TextCleaningManaging, @unchecked Sendable {
    typealias Handler = (_ text: String, _ prompt: String?, _ modelKind: LocalCleanupModelKind?, _ timeout: TimeInterval?) async throws -> String

    var handler: Handler
    private(set) var calls: [(text: String, prompt: String?, modelKind: LocalCleanupModelKind?, timeout: TimeInterval?)] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func clean(
        text: String,
        prompt: String?,
        modelKind: LocalCleanupModelKind?,
        timeout: TimeInterval?
    ) async throws -> String {
        calls.append((text: text, prompt: prompt, modelKind: modelKind, timeout: timeout))
        return try await handler(text, prompt, modelKind, timeout)
    }
}

@MainActor
final class MeetingSummaryGeneratorTests: XCTestCase {
    private func transcript(segmentCount: Int, segmentText: String = "hello world") -> MeetingTranscript {
        let t = MeetingTranscript(meetingName: "Test")
        for i in 0..<segmentCount {
            t.appendSegment(
                TranscriptSegment(
                    id: UUID(),
                    speaker: .me,
                    startTime: TimeInterval(i),
                    endTime: TimeInterval(i + 1),
                    text: segmentText
                )
            )
        }
        return t
    }

    func testThrowsWhenTranscriptIsEmpty() async {
        let stub = StubCleaningManager { _, _, _, _ in "unused" }
        let generator = MeetingSummaryGenerator(cleanupManager: stub)
        let t = transcript(segmentCount: 0)

        do {
            _ = try await generator.generateSummary(transcript: t)
            XCTFail("Expected throw")
        } catch {
            // expected
        }
        XCTAssertTrue(stub.calls.isEmpty)
    }

    func testReturnsSummaryAndPassesLongTimeoutForSingleChunk() async throws {
        let stub = StubCleaningManager { _, _, _, _ in "  the summary  " }
        let generator = MeetingSummaryGenerator(cleanupManager: stub)
        let t = transcript(segmentCount: 1)

        let result = try await generator.generateSummary(transcript: t)

        XCTAssertEqual(result, "the summary")
        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertEqual(stub.calls.first?.timeout, TextCleanupManager.summaryTimeoutSeconds)
    }

    func testThrowsFinalCombineFailedWhenSingleChunkReturnsBlank() async {
        let stub = StubCleaningManager { _, _, _, _ in "   " }
        let generator = MeetingSummaryGenerator(cleanupManager: stub)
        let t = transcript(segmentCount: 1)

        do {
            _ = try await generator.generateSummary(transcript: t)
            XCTFail("Expected throw")
        } catch let error as MeetingSummaryError {
            guard case .finalCombineFailed = error else {
                XCTFail("Expected finalCombineFailed, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testThrowsAllChunksFailedWhenEveryChunkFails() async {
        let longLine = String(repeating: "x", count: 200)
        let t = transcript(segmentCount: 50, segmentText: longLine)
        var loggedMessages: [String] = []
        let stub = StubCleaningManager { _, _, _, _ in
            throw CleanupBackendError.unavailable
        }

        let generator = MeetingSummaryGenerator(
            cleanupManager: stub,
            logger: { loggedMessages.append($0) }
        )

        do {
            _ = try await generator.generateSummary(transcript: t)
            XCTFail("Expected throw")
        } catch let error as MeetingSummaryError {
            guard case .allChunksFailed = error else {
                XCTFail("Expected allChunksFailed, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertGreaterThan(stub.calls.count, 1, "must have attempted multiple chunks")
        XCTAssertFalse(loggedMessages.isEmpty, "per-chunk failures should be logged")
    }

    func testToleratesPartialChunkFailureAndCombines() async throws {
        let longLine = String(repeating: "x", count: 200)
        let t = transcript(segmentCount: 50, segmentText: longLine)
        var callIndex = 0
        // Fail the second per-chunk call only; succeed for every other chunk
        // and for the final combine pass.
        let stub = StubCleaningManager { _, _, _, _ in
            defer { callIndex += 1 }
            if callIndex == 1 {
                throw CleanupBackendError.unusableOutput(rawOutput: "")
            }
            return "summary-\(callIndex)"
        }

        let generator = MeetingSummaryGenerator(cleanupManager: stub)
        let result = try await generator.generateSummary(transcript: t)

        XCTAssertFalse(result.isEmpty)
        XCTAssertGreaterThanOrEqual(stub.calls.count, 3, "should attempt all chunks plus the final combine")
    }
}
