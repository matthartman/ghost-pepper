import XCTest
@testable import GhostPepper

@MainActor
final class MeetingMarkdownWriterTests: XCTestCase {

    private var workDirectory: URL!

    override func setUp() {
        super.setUp()
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhostPepperMDTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
        super.tearDown()
    }

    private func tempFile(_ name: String = "test") -> URL {
        workDirectory.appendingPathComponent("\(name).md")
    }

    private func ymd(_ string: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: string)!
    }

    func testParseExpiredMarkerSetsExpiryDate() throws {
        let content = """
        # Test Meeting

        ## Notes

        Some notes.

        ## Summary

        The summary.

        ## Transcript

        *Transcript was automatically deleted on 2026-04-16 per your privacy settings.*

        <!-- ghost-pepper-transcript-expired: 2026-04-16 -->
        """
        let file = tempFile()
        try content.write(to: file, atomically: true, encoding: .utf8)

        let transcript = try MeetingMarkdownWriter.parse(from: file)

        XCTAssertNotNil(transcript.transcriptExpiredDate)
        XCTAssertEqual(transcript.transcriptExpiredDate, ymd("2026-04-16"))
        XCTAssertTrue(transcript.segments.isEmpty)
        XCTAssertEqual(transcript.summary, "The summary.")
        XCTAssertEqual(transcript.notes, "Some notes.")
    }

    func testFallbackParserDoesNotSwallowExpiredPlaceholder() throws {
        // Before the fix, the italic placeholder would be parsed as a
        // phantom segment by the Granola-style fallback parser.
        let content = """
        # Expired Meeting

        ## Transcript

        *Transcript was automatically deleted on 2026-04-16 per your privacy settings.*

        <!-- ghost-pepper-transcript-expired: 2026-04-16 -->
        """
        let file = tempFile()
        try content.write(to: file, atomically: true, encoding: .utf8)

        let transcript = try MeetingMarkdownWriter.parse(from: file)

        XCTAssertTrue(transcript.segments.isEmpty,
                      "Expected no phantom segments for expired transcript, got \(transcript.segments.count)")
    }

    func testRenderThenParseRoundTripsExpiredState() throws {
        let transcript = MeetingTranscript(
            meetingName: "Round Trip Test",
            startDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        transcript.notes = "Project notes."
        transcript.summary = "A pithy summary."
        transcript.transcriptExpiredDate = ymd("2026-04-16")

        let markdown = MeetingMarkdownWriter.renderMarkdown(transcript: transcript)
        XCTAssertTrue(markdown.contains("<!-- ghost-pepper-transcript-expired: 2026-04-16 -->"),
                      "renderMarkdown should emit the expiry marker when transcriptExpiredDate is set")

        let file = tempFile()
        try markdown.write(to: file, atomically: true, encoding: .utf8)
        let parsed = try MeetingMarkdownWriter.parse(from: file)

        XCTAssertEqual(parsed.transcriptExpiredDate, ymd("2026-04-16"))
        XCTAssertTrue(parsed.segments.isEmpty)
        XCTAssertEqual(parsed.notes, "Project notes.")
        XCTAssertEqual(parsed.summary, "A pithy summary.")
    }

    func testRenderPrefersSegmentsWhenBothSetAsDefensiveGuard() throws {
        // Defensive: if transcriptExpiredDate is accidentally set on a live transcript
        // with actual segments, prefer data preservation over the expired banner.
        // Reaching this state is a bug, but rendering must not silently drop segments.
        let transcript = MeetingTranscript(meetingName: "Live")
        transcript.segments = [
            TranscriptSegment(id: UUID(), speaker: .me, startTime: 0, endTime: 5, text: "live content")
        ]
        transcript.transcriptExpiredDate = ymd("2026-04-16")

        let markdown = MeetingMarkdownWriter.renderMarkdown(transcript: transcript)

        XCTAssertTrue(markdown.contains("live content"),
                      "When segments exist, render must preserve them even if expired flag is set")
        XCTAssertFalse(markdown.contains("<!-- ghost-pepper-transcript-expired:"),
                       "Should not emit marker when segments exist")
    }

    func testWriteDoesNotClobberOnDiskExpiredMarker() throws {
        // Race case: a tab was opened with full segments, sweeper stripped the file,
        // then autoSave fires with the stale in-memory transcript. The write path must
        // honor the on-disk expiry marker instead of resurrecting the deleted segments.
        let baseDir = workDirectory.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let expiredContent = """
        # Test

        ## Notes

        Preserved notes.

        ## Transcript

        *Transcript was automatically deleted on 2026-04-16 per your privacy settings.*

        <!-- ghost-pepper-transcript-expired: 2026-04-16 -->

        """
        let existing = baseDir.appendingPathComponent("stale.md")
        try expiredContent.write(to: existing, atomically: true, encoding: .utf8)

        let stale = MeetingTranscript(meetingName: "Test")
        stale.notes = "Preserved notes."
        stale.segments = [
            TranscriptSegment(id: UUID(), speaker: .me, startTime: 0, endTime: 5,
                              text: "I should have been deleted")
        ]

        _ = try MeetingMarkdownWriter.write(
            transcript: stale,
            to: baseDir,
            existingFileURL: existing
        )

        let after = try String(contentsOf: existing, encoding: .utf8)
        XCTAssertFalse(after.contains("I should have been deleted"),
                       "Stale in-memory segments must not resurrect a swept file")
        XCTAssertTrue(after.contains("<!-- ghost-pepper-transcript-expired: 2026-04-16 -->"),
                      "On-disk expiry marker must be preserved")
        XCTAssertTrue(after.contains("Preserved notes."),
                      "Notes from in-memory transcript should still be written")
    }

    func testParseHandlesHeaderWithTrailingWhitespace() throws {
        // Header line "## Transcript   " with trailing spaces should still be matched.
        let content = "# Test\n\n## Transcript   \n\n**[00:00] Me:** hello\n"
        let file = tempFile()
        try content.write(to: file, atomically: true, encoding: .utf8)

        let transcript = try MeetingMarkdownWriter.parse(from: file)

        XCTAssertEqual(transcript.segments.count, 1,
                       "Parser must match '## Transcript' header with trailing whitespace")
    }

    func testRenderEmitsAutoDeleteFrontmatterWhenFlagged() {
        let transcript = MeetingTranscript(meetingName: "Sensitive")
        transcript.autoDeleteFlagged = true
        transcript.notes = "Private stuff."

        let markdown = MeetingMarkdownWriter.renderMarkdown(transcript: transcript)

        XCTAssertTrue(markdown.hasPrefix("---\n"),
                      "Flagged transcript must start with a YAML frontmatter fence")
        XCTAssertTrue(markdown.contains("\nauto_delete: true\n"),
                      "Flagged transcript must include `auto_delete: true` in frontmatter")
    }

    func testRenderOmitsFrontmatterWhenNotFlagged() {
        let transcript = MeetingTranscript(meetingName: "Regular")
        transcript.autoDeleteFlagged = false

        let markdown = MeetingMarkdownWriter.renderMarkdown(transcript: transcript)

        XCTAssertFalse(markdown.hasPrefix("---\n"),
                       "Unflagged transcripts should not emit YAML frontmatter")
        XCTAssertFalse(markdown.contains("auto_delete"),
                       "Unflagged transcripts should not mention auto_delete")
    }

    func testParseReadsAutoDeleteFlag() throws {
        let content = """
        ---
        auto_delete: true
        ---

        # Test

        ## Notes

        Notes here.

        """
        let file = tempFile()
        try content.write(to: file, atomically: true, encoding: .utf8)

        let transcript = try MeetingMarkdownWriter.parse(from: file)

        XCTAssertTrue(transcript.autoDeleteFlagged, "Parser must read auto_delete flag from frontmatter")
    }

    func testParseMissingFlagDefaultsToFalse() throws {
        let content = """
        # Test

        ## Notes

        Notes.

        """
        let file = tempFile()
        try content.write(to: file, atomically: true, encoding: .utf8)

        let transcript = try MeetingMarkdownWriter.parse(from: file)

        XCTAssertFalse(transcript.autoDeleteFlagged, "Absent flag must default to false")
    }

    func testAutoDeleteFlagSurvivesRoundTrip() throws {
        let transcript = MeetingTranscript(meetingName: "Round Trip")
        transcript.notes = "Body."
        transcript.autoDeleteFlagged = true

        let markdown = MeetingMarkdownWriter.renderMarkdown(transcript: transcript)
        let file = tempFile()
        try markdown.write(to: file, atomically: true, encoding: .utf8)
        let parsed = try MeetingMarkdownWriter.parse(from: file)

        XCTAssertTrue(parsed.autoDeleteFlagged)
        XCTAssertEqual(parsed.notes, "Body.")
    }

    func testParseHandlesUTF8BOM() throws {
        let content = "\u{FEFF}" + """
        # Test

        ## Transcript

        **[00:00] Me:** hello

        """
        let file = tempFile()
        try content.write(to: file, atomically: true, encoding: .utf8)

        let transcript = try MeetingMarkdownWriter.parse(from: file)

        XCTAssertEqual(transcript.segments.count, 1,
                       "Parser must tolerate a leading UTF-8 BOM")
    }
}
