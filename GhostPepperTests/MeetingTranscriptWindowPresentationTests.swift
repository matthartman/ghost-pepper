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

@MainActor
final class QAAnswerCitationsTests: XCTestCase {
    func testPreprocessLinksMeetingLineCitations() {
        let processed = QAAnswerCitations.preprocess(
            "See 2026-04-28/standup.md:71-72 for the original quote."
        )
        XCTAssertTrue(
            processed.contains("[2026-04-28/standup.md:71-72](gp://meeting/2026-04-28/standup.md?line=71)"),
            processed
        )
    }

    func testPreprocessLinksPersonWikilinks() {
        let processed = QAAnswerCitations.preprocess("Follow up with [[Owen Blake Carter]].")
        XCTAssertTrue(
            processed.contains("[Owen Blake Carter](gp://person/people/owen-blake-carter)"),
            processed
        )
    }
}

@MainActor
final class MeetingMarkdownWriterTests: XCTestCase {
    func testGranolaImportRoundTripPreservesFrontmatterDateAndRawTranscript() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("jay-taylor-navan-chauhan-matt-hartman.md")
        let original = """
        ---
        title: "Jay Taylor & Navan Chauhan <> Matt Hartman"
        date: "2026-05-26T20:01:18.803Z"
        granola_id: "not_FTrJiW1VXfbWSj"
        source_type: meeting
        imported_from: granola
        ---

        # Jay Taylor & Navan Chauhan <> Matt Hartman

        ## Summary

        ### Company Background

        - Started July 2025

        ## Transcript

        Chat with meeting transcript: [https://notes.granola.ai/t/example](https://notes.granola.ai/t/example)

        Hello from the raw Granola transcript.
        """
        try original.write(to: fileURL, atomically: true, encoding: .utf8)

        let transcript = try MeetingMarkdownWriter.parse(from: fileURL)
        transcript.summary = transcript.summary?.replacingOccurrences(of: "Started", with: "Began")

        let rendered = MeetingMarkdownWriter.renderMarkdown(transcript: transcript)

        XCTAssertTrue(rendered.contains("granola_id: \"not_FTrJiW1VXfbWSj\""))
        XCTAssertTrue(rendered.contains("date: \"2026-05-26T20:01:18.803Z\""))
        XCTAssertTrue(rendered.contains("imported_from: granola"))
        XCTAssertTrue(rendered.contains("Hello from the raw Granola transcript."))
        XCTAssertTrue(rendered.contains("- Began July 2025"))
        XCTAssertFalse(rendered.contains("*No transcript yet.*"))
        XCTAssertFalse(rendered.contains("**Date:**"))
    }
}
