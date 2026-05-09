import AppKit
import XCTest
@testable import GhostPepper

final class MeetingTranscriptWindowPresentationTests: XCTestCase {
    func testWindowStaysNormalWhenFloatingPreferenceIsDisabled() {
        XCTAssertEqual(
            MeetingTranscriptWindowPresentation.windowLevel(
                shouldFloatWhileRecording: false,
                hasActiveRecording: true
            ),
            .normal
        )
    }

    func testWindowFloatsWhenRecordingAndFloatingPreferenceIsEnabled() {
        XCTAssertEqual(
            MeetingTranscriptWindowPresentation.windowLevel(
                shouldFloatWhileRecording: true,
                hasActiveRecording: true
            ),
            .floating
        )
    }

    func testWindowReturnsToNormalWhenNoMeetingIsRecording() {
        XCTAssertEqual(
            MeetingTranscriptWindowPresentation.windowLevel(
                shouldFloatWhileRecording: true,
                hasActiveRecording: false
            ),
            .normal
        )
    }

    func testSummaryViewStateShowsRecordingPlaceholderWhileRecording() {
        XCTAssertEqual(
            MeetingTranscriptWindowPresentation.summaryViewState(
                isRecording: true,
                isGeneratingSummary: false,
                summary: nil,
                summaryError: nil,
                hasSegments: true
            ),
            .recordingPlaceholder
        )
    }

    func testSummaryViewStateShowsSpinnerWhileGenerating() {
        XCTAssertEqual(
            MeetingTranscriptWindowPresentation.summaryViewState(
                isRecording: false,
                isGeneratingSummary: true,
                summary: nil,
                summaryError: nil,
                hasSegments: true
            ),
            .generatingSpinner
        )
    }

    func testSummaryViewStateShowsSummaryWhenPresent() {
        XCTAssertEqual(
            MeetingTranscriptWindowPresentation.summaryViewState(
                isRecording: false,
                isGeneratingSummary: false,
                summary: "result",
                summaryError: nil,
                hasSegments: true
            ),
            .showSummary
        )
    }

    func testSummaryViewStateShowsFailureWhenErrorPresentAndNoSummary() {
        XCTAssertEqual(
            MeetingTranscriptWindowPresentation.summaryViewState(
                isRecording: false,
                isGeneratingSummary: false,
                summary: nil,
                summaryError: "Could not produce summary: timed out",
                hasSegments: true
            ),
            .failure(message: "Could not produce summary: timed out")
        )
    }

    func testSummaryViewStateShowsGeneratePromptWhenSegmentsExistAndNoError() {
        XCTAssertEqual(
            MeetingTranscriptWindowPresentation.summaryViewState(
                isRecording: false,
                isGeneratingSummary: false,
                summary: nil,
                summaryError: nil,
                hasSegments: true
            ),
            .generatePrompt
        )
    }

    func testSummaryViewStateShowsNoTranscriptWhenSegmentsEmpty() {
        XCTAssertEqual(
            MeetingTranscriptWindowPresentation.summaryViewState(
                isRecording: false,
                isGeneratingSummary: false,
                summary: nil,
                summaryError: nil,
                hasSegments: false
            ),
            .noTranscript
        )
    }

    func testSummaryViewStatePrefersSpinnerOverError() {
        XCTAssertEqual(
            MeetingTranscriptWindowPresentation.summaryViewState(
                isRecording: false,
                isGeneratingSummary: true,
                summary: nil,
                summaryError: "stale error",
                hasSegments: true
            ),
            .generatingSpinner
        )
    }
}
