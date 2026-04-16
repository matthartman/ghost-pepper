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
}
