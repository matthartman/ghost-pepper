import XCTest
@testable import GhostPepper

@MainActor
final class PerformanceTraceTests: XCTestCase {
    func testSummaryReportsExpectedStageDurations() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        var trace = PerformanceTrace(sessionID: "session-1", startedAt: startedAt)

        trace.hotkeyDetectedAt = startedAt
        trace.micLiveAt = startedAt.addingTimeInterval(0.08)
        trace.hotkeyLiftedAt = startedAt.addingTimeInterval(1.30)
        trace.micColdAt = startedAt.addingTimeInterval(1.55)
        trace.transcriptionStartAt = startedAt.addingTimeInterval(1.55)
        trace.transcriptionEndAt = startedAt.addingTimeInterval(2.05)
        trace.cleanupStartAt = startedAt.addingTimeInterval(2.05)
        trace.cleanupEndAt = startedAt.addingTimeInterval(2.42)
        trace.ocrCaptureDuration = 0.41
        trace.promptBuildDuration = 0.02
        trace.modelCallDuration = 0.64
        trace.postProcessDuration = 0.21
        trace.pasteStartAt = startedAt.addingTimeInterval(2.43)
        trace.pasteEndAt = startedAt.addingTimeInterval(2.59)

        let summary = trace.summary(
            speechModelID: "parakeet-v3",
            cleanupBackend: .localModels,
            cleanupAttempted: true
        )

        XCTAssertTrue(summary.contains("session=session-1"))
        XCTAssertTrue(summary.contains("speechModel=parakeet-v3"))
        XCTAssertTrue(summary.contains("hotkey_to_mic_live=80ms"))
        XCTAssertTrue(summary.contains("hotkey_lift_to_mic_cold=250ms"))
        XCTAssertTrue(summary.contains("transcription=500ms"))
        XCTAssertTrue(summary.contains("cleanup=370ms"))
        XCTAssertTrue(summary.contains("ocr=410ms"))
        XCTAssertTrue(summary.contains("prompt_build=20ms"))
        XCTAssertTrue(summary.contains("model_call=640ms"))
        XCTAssertTrue(summary.contains("post_process=210ms"))
        XCTAssertTrue(summary.contains("paste=160ms"))
        XCTAssertTrue(summary.contains("total=2590ms"))
    }

    func testSummaryMarksSkippedCleanupWhenItWasNotAttempted() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 200)
        var trace = PerformanceTrace(sessionID: "session-2", startedAt: startedAt)
        trace.hotkeyDetectedAt = startedAt
        trace.micLiveAt = startedAt.addingTimeInterval(0.04)
        trace.hotkeyLiftedAt = startedAt.addingTimeInterval(0.80)
        trace.micColdAt = startedAt.addingTimeInterval(1.00)
        trace.transcriptionStartAt = startedAt.addingTimeInterval(1.00)
        trace.transcriptionEndAt = startedAt.addingTimeInterval(1.48)
        trace.pasteStartAt = startedAt.addingTimeInterval(1.49)
        trace.pasteEndAt = startedAt.addingTimeInterval(1.63)

        let summary = trace.summary(
            speechModelID: "openai_whisper-small.en",
            cleanupBackend: .localModels,
            cleanupAttempted: false
        )

        XCTAssertTrue(summary.contains("cleanup=skipped"))
    }

    func testSummaryIncludesWhisperCppLargeV3TurboQuantizedSpeechModelID() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 400)
        var trace = PerformanceTrace(sessionID: "session-4", startedAt: startedAt)
        trace.hotkeyDetectedAt = startedAt
        trace.micLiveAt = startedAt.addingTimeInterval(0.04)
        trace.hotkeyLiftedAt = startedAt.addingTimeInterval(0.82)
        trace.micColdAt = startedAt.addingTimeInterval(1.01)
        trace.transcriptionStartAt = startedAt.addingTimeInterval(1.01)
        trace.transcriptionEndAt = startedAt.addingTimeInterval(1.71)

        let summary = trace.summary(
            speechModelID: "ggml-large-v3-turbo-q5_0",
            cleanupBackend: .localModels,
            cleanupAttempted: false
        )

        XCTAssertTrue(summary.contains("speechModel=ggml-large-v3-turbo-q5_0"))
    }

    func testSummaryIncludesWhisperCppLargeV3TurboSpeechModelID() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 500)
        var trace = PerformanceTrace(sessionID: "session-5", startedAt: startedAt)
        trace.hotkeyDetectedAt = startedAt
        trace.micLiveAt = startedAt.addingTimeInterval(0.06)
        trace.hotkeyLiftedAt = startedAt.addingTimeInterval(0.95)
        trace.micColdAt = startedAt.addingTimeInterval(1.16)
        trace.transcriptionStartAt = startedAt.addingTimeInterval(1.16)
        trace.transcriptionEndAt = startedAt.addingTimeInterval(1.89)

        let summary = trace.summary(
            speechModelID: "ggml-large-v3-turbo",
            cleanupBackend: .localModels,
            cleanupAttempted: false
        )

        XCTAssertTrue(summary.contains("speechModel=ggml-large-v3-turbo"))
    }
}
