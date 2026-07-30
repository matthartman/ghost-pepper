import XCTest
@testable import GhostPepper

@MainActor
final class MeetingSummaryGeneratorTests: XCTestCase {
    private func makeMultiChunkTranscript(chunkCount: Int) -> MeetingTranscript {
        let transcript = MeetingTranscript(meetingName: "Job Interview with Eric Brengle")
        // ~6000 chars: bigger than the 5000-char chunk limit on its own,
        // so each segment becomes exactly one chunk.
        let oversizedText = String(repeating: "word ", count: 1200)
        for i in 0..<chunkCount {
            transcript.appendSegment(
                TranscriptSegment(
                    id: UUID(),
                    speaker: .remote(name: "Eric"),
                    startTime: TimeInterval(i * 60),
                    endTime: TimeInterval(i * 60 + 30),
                    text: "\(oversizedText) segment \(i)"
                )
            )
        }
        return transcript
    }

    private func makeSingleChunkTranscript() -> MeetingTranscript {
        let transcript = MeetingTranscript(meetingName: "Quick Sync")
        transcript.appendSegment(
            TranscriptSegment(
                id: UUID(),
                speaker: .remote(name: "Eric"),
                startTime: 0,
                endTime: 30,
                text: "Short meeting transcript."
            )
        )
        return transcript
    }

    func testGenerateSummarySucceedsLogsStartAndRollup() async {
        let transcript = makeMultiChunkTranscript(chunkCount: 3)
        var callCount = 0
        let cleanupManager = TextCleanupManager(
            selectedCleanupModelKind: .qwen35_0_8b_q4_k_m,
            cleanupModelAvailabilityOverrides: [.qwen35_0_8b_q4_k_m: true],
            probeExecutionOverride: { _, _, modelKind, _ in
                callCount += 1
                return CleanupModelProbeRawResult(
                    modelKind: modelKind,
                    modelDisplayName: "test",
                    rawOutput: "Summary for call \(callCount)",
                    elapsed: 0.01
                )
            }
        )
        let generator = MeetingSummaryGenerator(cleanupManager: cleanupManager)
        var logged: [(DebugLogCategory, String)] = []
        generator.debugLogger = { logged.append(($0, $1)) }

        let summary = await generator.generateSummary(transcript: transcript)

        XCTAssertNotNil(summary)
        XCTAssertTrue(logged.contains {
            $0.1.contains("starting for") && $0.1.contains("3 chunk(s)")
        })
        XCTAssertTrue(logged.contains {
            $0.1.contains("chunk summarization complete — 3/3 chunks succeeded")
        })
        XCTAssertFalse(logged.contains { $0.1.contains("failed") })
    }

    func testGenerateSummaryLogsChunkFailureAndStillSucceeds() async {
        let transcript = makeMultiChunkTranscript(chunkCount: 3)
        var callCount = 0
        let cleanupManager = TextCleanupManager(
            selectedCleanupModelKind: .qwen35_0_8b_q4_k_m,
            cleanupModelAvailabilityOverrides: [.qwen35_0_8b_q4_k_m: true],
            probeExecutionOverride: { _, _, modelKind, _ in
                callCount += 1
                if callCount == 2 {
                    return CleanupModelProbeRawResult(
                        modelKind: modelKind,
                        modelDisplayName: "test",
                        rawOutput: "...",
                        elapsed: 0.01
                    )
                }
                return CleanupModelProbeRawResult(
                    modelKind: modelKind,
                    modelDisplayName: "test",
                    rawOutput: "Summary for call \(callCount)",
                    elapsed: 0.01
                )
            }
        )
        let generator = MeetingSummaryGenerator(cleanupManager: cleanupManager)
        var logged: [(DebugLogCategory, String)] = []
        generator.debugLogger = { logged.append(($0, $1)) }

        let summary = await generator.generateSummary(transcript: transcript)

        XCTAssertNotNil(summary)
        XCTAssertTrue(logged.contains {
            $0.1.contains("chunk 2/3 failed") &&
            $0.1.contains("returned unusable output") &&
            $0.1.contains("dropped from summary")
        })
        XCTAssertTrue(logged.contains {
            $0.1.contains("chunk summarization complete — 2/3 chunks succeeded")
        })
    }

    func testGenerateSummaryLogsFinalCombineFailureAndDiscardsChunkSummaries() async {
        let transcript = makeMultiChunkTranscript(chunkCount: 3)
        var callCount = 0
        let cleanupManager = TextCleanupManager(
            selectedCleanupModelKind: .qwen35_0_8b_q4_k_m,
            cleanupModelAvailabilityOverrides: [.qwen35_0_8b_q4_k_m: true],
            probeExecutionOverride: { _, _, modelKind, _ in
                callCount += 1
                if callCount == 4 {
                    throw CancellationError()
                }
                return CleanupModelProbeRawResult(
                    modelKind: modelKind,
                    modelDisplayName: "test",
                    rawOutput: "Summary for call \(callCount)",
                    elapsed: 0.01
                )
            }
        )
        let generator = MeetingSummaryGenerator(cleanupManager: cleanupManager)
        var logged: [(DebugLogCategory, String)] = []
        generator.debugLogger = { logged.append(($0, $1)) }

        let summary = await generator.generateSummary(transcript: transcript)

        XCTAssertNil(summary)
        XCTAssertTrue(logged.contains {
            $0.1.contains("final combine step failed") &&
            $0.1.contains("timed out after 15s") &&
            $0.1.contains("3/3 chunk summaries discarded")
        })
    }

    func testGenerateSummarySingleChunkCombineFailureHasNoRollupLine() async {
        let transcript = makeSingleChunkTranscript()
        let cleanupManager = TextCleanupManager(
            selectedCleanupModelKind: .qwen35_0_8b_q4_k_m,
            cleanupModelAvailabilityOverrides: [.qwen35_0_8b_q4_k_m: true],
            probeExecutionOverride: { _, _, _, _ in
                throw CancellationError()
            }
        )
        let generator = MeetingSummaryGenerator(cleanupManager: cleanupManager)
        var logged: [(DebugLogCategory, String)] = []
        generator.debugLogger = { logged.append(($0, $1)) }

        let summary = await generator.generateSummary(transcript: transcript)

        XCTAssertNil(summary)
        XCTAssertFalse(logged.contains { $0.1.contains("chunk summarization complete") })
        XCTAssertTrue(logged.contains {
            $0.1.contains("final combine step failed") &&
            $0.1.contains("timed out after 15s")
        })
    }
}
