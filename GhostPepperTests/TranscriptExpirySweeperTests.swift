import XCTest
@testable import GhostPepper

final class TranscriptExpirySweeperTests: XCTestCase {
    private var baseDirectory: URL!
    private var fileManager: FileManager { .default }

    override func setUp() {
        super.setUp()
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhostPepperExpiryTests-\(UUID().uuidString)")
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let baseDirectory {
            try? fileManager.removeItem(at: baseDirectory)
        }
        baseDirectory = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A meeting the user has flagged for auto-delete. This is the default fixture
    /// because the sweeper only acts on flagged files; an unflagged file is never
    /// touched regardless of age.
    private let fullMeetingMarkdown = """
    ---
    auto_delete: true
    ---

    # Test Meeting

    **Date:** Jan 1, 2026 at 10:00 AM

    ## Notes

    Some notes here.

    ## Summary

    A summary of what happened.

    ## Transcript

    **[00:00] Me:** Hello.
    **[00:30] Others:** Hi there.

    """

    /// Same content but without the `auto_delete: true` flag — the sweeper must
    /// leave this alone regardless of age.
    private let unflaggedMeetingMarkdown = """
    # Test Meeting

    **Date:** Jan 1, 2026 at 10:00 AM

    ## Notes

    Some notes here.

    ## Summary

    A summary of what happened.

    ## Transcript

    **[00:00] Me:** Hello.
    **[00:30] Others:** Hi there.

    """

    private func writeMeeting(folder: String, name: String, content: String) throws -> URL {
        let dir = baseDirectory.appendingPathComponent(folder)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(name).md")
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func localDate(_ ymd: String, hour: Int = 12) -> Date {
        var comps = DateComponents()
        let parts = ymd.split(separator: "-").compactMap { Int($0) }
        precondition(parts.count == 3, "expected yyyy-MM-dd, got \(ymd)")
        comps.year = parts[0]
        comps.month = parts[1]
        comps.day = parts[2]
        comps.hour = hour
        return Calendar.current.date(from: comps)!
    }

    // MARK: - Tests

    func testExpiredMeetingHasTranscriptStripped() throws {
        let file = try writeMeeting(folder: "2026-01-01", name: "standup", content: fullMeetingMarkdown)
        let count = TranscriptExpirySweeper.run(
            baseDirectory: baseDirectory,
            daysToKeep: 30,
            now: localDate("2026-04-16")
        )
        XCTAssertEqual(count.expiredCount, 1)
        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(after.contains("**[00:00] Me:** Hello."))
        XCTAssertFalse(after.contains("**[00:30] Others:** Hi there."))
        XCTAssertTrue(after.contains("Transcript was automatically deleted"))
        XCTAssertTrue(after.contains("<!-- ghost-pepper-transcript-expired:"))
    }

    func testRecentMeetingIsUntouched() throws {
        let file = try writeMeeting(folder: "2026-04-11", name: "standup", content: fullMeetingMarkdown)
        let before = try String(contentsOf: file, encoding: .utf8)
        let count = TranscriptExpirySweeper.run(
            baseDirectory: baseDirectory,
            daysToKeep: 30,
            now: localDate("2026-04-16")
        )
        XCTAssertEqual(count.expiredCount, 0)
        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(after, before)
    }

    func testPreservesSummaryAndNotes() throws {
        let file = try writeMeeting(folder: "2026-01-01", name: "standup", content: fullMeetingMarkdown)
        _ = TranscriptExpirySweeper.run(
            baseDirectory: baseDirectory,
            daysToKeep: 30,
            now: localDate("2026-04-16")
        )
        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(after.contains("## Notes"))
        XCTAssertTrue(after.contains("Some notes here."))
        XCTAssertTrue(after.contains("## Summary"))
        XCTAssertTrue(after.contains("A summary of what happened."))
    }

    func testIdempotentOnAlreadyExpired() throws {
        let file = try writeMeeting(folder: "2026-01-01", name: "standup", content: fullMeetingMarkdown)
        _ = TranscriptExpirySweeper.run(
            baseDirectory: baseDirectory,
            daysToKeep: 30,
            now: localDate("2026-04-16")
        )
        let afterFirst = try String(contentsOf: file, encoding: .utf8)
        let count = TranscriptExpirySweeper.run(
            baseDirectory: baseDirectory,
            daysToKeep: 30,
            now: localDate("2026-04-16")
        )
        XCTAssertEqual(count.expiredCount, 0, "Already-expired file should not be rewritten")
        let afterSecond = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(afterFirst, afterSecond)
    }

    func testNeverSettingIsNoOp() throws {
        let file = try writeMeeting(folder: "2020-01-01", name: "ancient", content: fullMeetingMarkdown)
        let before = try String(contentsOf: file, encoding: .utf8)
        let count = TranscriptExpirySweeper.run(
            baseDirectory: baseDirectory,
            daysToKeep: 0,
            now: localDate("2026-04-16")
        )
        XCTAssertEqual(count.expiredCount, 0)
        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(after, before)
    }

    func testNonDateFolderIsSkipped() throws {
        let file = try writeMeeting(folder: "archive", name: "special", content: fullMeetingMarkdown)
        let before = try String(contentsOf: file, encoding: .utf8)
        _ = TranscriptExpirySweeper.run(
            baseDirectory: baseDirectory,
            daysToKeep: 30,
            now: localDate("2026-04-16")
        )
        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(after, before)
    }

    func testBoundaryExpiresAtExactlyNDays() throws {
        // 2026-03-17 → 2026-04-16 is exactly 30 calendar days.
        // Rule: age >= daysToKeep expires.
        let file = try writeMeeting(folder: "2026-03-17", name: "standup", content: fullMeetingMarkdown)
        _ = TranscriptExpirySweeper.run(
            baseDirectory: baseDirectory,
            daysToKeep: 30,
            now: localDate("2026-04-16")
        )
        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(after.contains("<!-- ghost-pepper-transcript-expired:"))
    }

    func testNeverTranscribedMeetingIsUntouched() throws {
        // Meetings that were auto-detected but never actually transcribed have only
        // "*No transcript yet.*" in their Transcript section. Those should not be
        // stamped as "auto-deleted" because nothing was ever there to delete.
        let neverTranscribed = """
        # Empty Meeting

        ## Notes

        Just auto-detected.

        ## Transcript

        *No transcript yet.*

        """
        let file = try writeMeeting(folder: "2026-01-01", name: "empty", content: neverTranscribed)
        let before = try String(contentsOf: file, encoding: .utf8)
        let count = TranscriptExpirySweeper.run(
            baseDirectory: baseDirectory,
            daysToKeep: 30,
            now: localDate("2026-04-16")
        )
        XCTAssertEqual(count.expiredCount, 0)
        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(after, before, "A meeting with no transcript content should not be stamped as expired")
    }

    func testPreservesSectionsAfterTranscript() throws {
        // If any ## section appears after ## Transcript (e.g. Granola's ## Chapters),
        // the sweeper must keep it — only the transcript body should be stripped.
        let withTrailing = """
        ---
        auto_delete: true
        ---

        # Meeting With Chapters

        ## Notes

        Notes here.

        ## Transcript

        **[00:00] Me:** Hello.
        **[00:30] Others:** Hi.

        ## Chapters

        - 00:00 Introductions
        - 05:00 Roadmap

        """
        let file = try writeMeeting(folder: "2026-01-01", name: "chapters", content: withTrailing)
        _ = TranscriptExpirySweeper.run(
            baseDirectory: baseDirectory,
            daysToKeep: 30,
            now: localDate("2026-04-16")
        )
        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(after.contains("**[00:00] Me:** Hello."), "Transcript body should be stripped")
        XCTAssertTrue(after.contains("<!-- ghost-pepper-transcript-expired:"))
        XCTAssertTrue(after.contains("## Chapters"), "Chapters heading must survive")
        XCTAssertTrue(after.contains("- 00:00 Introductions"), "Chapter body must survive")
        XCTAssertTrue(after.contains("- 05:00 Roadmap"))
    }

    func testMeetingWithNoTranscriptSection() throws {
        let notesOnly = """
        # Notes-only Meeting

        ## Notes

        Just some notes, no transcript recorded.

        """
        let file = try writeMeeting(folder: "2026-01-01", name: "notesonly", content: notesOnly)
        let before = try String(contentsOf: file, encoding: .utf8)
        _ = TranscriptExpirySweeper.run(
            baseDirectory: baseDirectory,
            daysToKeep: 30,
            now: localDate("2026-04-16")
        )
        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(after, before, "File with no ## Transcript section should be left alone")
    }

    func testHandlesCRLFLineEndings() throws {
        // A file imported from a tool that writes Windows line endings should still
        // match the "## Transcript" header and be swept correctly.
        let crlfContent = fullMeetingMarkdown.replacingOccurrences(of: "\n", with: "\r\n")
        let file = try writeMeeting(folder: "2026-01-01", name: "crlf", content: crlfContent)
        let count = TranscriptExpirySweeper.run(
            baseDirectory: baseDirectory,
            daysToKeep: 30,
            now: localDate("2026-04-16")
        )
        XCTAssertEqual(count.expiredCount, 1)
        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(after.contains("**[00:00] Me:** Hello."))
        XCTAssertTrue(after.contains("<!-- ghost-pepper-transcript-expired:"))
    }

    func testUnflaggedOldMeetingIsNotSwept() throws {
        // A meeting old enough to expire must NOT be swept if the user hasn't
        // flagged it for auto-delete. Opt-in, not opt-out.
        let file = try writeMeeting(folder: "2026-01-01", name: "unflagged", content: unflaggedMeetingMarkdown)
        let before = try String(contentsOf: file, encoding: .utf8)
        let count = TranscriptExpirySweeper.run(
            baseDirectory: baseDirectory,
            daysToKeep: 30,
            now: localDate("2026-04-16")
        )
        XCTAssertEqual(count.expiredCount, 0, "Unflagged meetings must never be swept")
        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(after, before, "Unflagged file must be untouched")
    }

    func testMixedFlaggedAndUnflaggedFolder() throws {
        // Same folder, same age; only the flagged file should be swept.
        let flagged = try writeMeeting(folder: "2026-01-01", name: "flagged", content: fullMeetingMarkdown)
        let unflagged = try writeMeeting(folder: "2026-01-01", name: "normal", content: unflaggedMeetingMarkdown)
        let unflaggedBefore = try String(contentsOf: unflagged, encoding: .utf8)

        let result = TranscriptExpirySweeper.run(
            baseDirectory: baseDirectory,
            daysToKeep: 30,
            now: localDate("2026-04-16")
        )

        XCTAssertEqual(result.expiredCount, 1)
        let flaggedAfter = try String(contentsOf: flagged, encoding: .utf8)
        XCTAssertTrue(flaggedAfter.contains("<!-- ghost-pepper-transcript-expired:"))
        let unflaggedAfter = try String(contentsOf: unflagged, encoding: .utf8)
        XCTAssertEqual(unflaggedAfter, unflaggedBefore)
    }

    func testHeaderWithTrailingWhitespaceIsMatched() throws {
        // A header like "## Transcript   " with trailing whitespace (e.g. from manual edits)
        // must still be recognized by the sweeper.
        let content = "---\nauto_delete: true\n---\n\n# Test Meeting\n\n## Notes\n\nNote.\n\n## Transcript   \n\n**[00:00] Me:** hello\n"
        let file = try writeMeeting(folder: "2026-01-01", name: "trailing", content: content)
        let count = TranscriptExpirySweeper.run(
            baseDirectory: baseDirectory,
            daysToKeep: 30,
            now: localDate("2026-04-16")
        )
        XCTAssertEqual(count.expiredCount, 1)
        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(after.contains("**[00:00] Me:** hello"))
        XCTAssertTrue(after.contains("<!-- ghost-pepper-transcript-expired:"))
    }

    func testFileWithUTF8BOMIsSwept() throws {
        // Files starting with a UTF-8 BOM (0xFEFF) should still parse and sweep.
        let content = "\u{FEFF}" + fullMeetingMarkdown
        let file = try writeMeeting(folder: "2026-01-01", name: "bom", content: content)
        let result = TranscriptExpirySweeper.run(
            baseDirectory: baseDirectory,
            daysToKeep: 30,
            now: localDate("2026-04-16")
        )
        XCTAssertEqual(result.expiredCount, 1)
        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(after.contains("**[00:00] Me:** Hello."))
        XCTAssertTrue(after.contains("<!-- ghost-pepper-transcript-expired:"))
    }

    func testMissingBaseDirectoryIsSilentNoOp() {
        // A user who hasn't opened a meeting yet has no base dir. The sweep should
        // silently no-op — NOT record an error for normal first-launch state.
        let nonexistent = baseDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        let result = TranscriptExpirySweeper.run(baseDirectory: nonexistent, daysToKeep: 30)
        XCTAssertEqual(result.expiredCount, 0)
        XCTAssertTrue(result.errors.isEmpty,
                      "A missing base directory is normal first-launch state and must not log an error")
    }

    func testUnreadableBaseDirectoryRecordsError() throws {
        // If the base directory exists but is actually a file (or is unreadable),
        // the sweep must record an error instead of silently failing.
        let fileMasqueradingAsDir = baseDirectory.appendingPathComponent("not-a-dir-\(UUID().uuidString)")
        try Data().write(to: fileMasqueradingAsDir)
        let result = TranscriptExpirySweeper.run(baseDirectory: fileMasqueradingAsDir, daysToKeep: 30)
        XCTAssertFalse(result.errors.isEmpty,
                       "A base directory that exists but isn't readable as a directory must record an error")
    }

    func testMultipleMeetingsMixedAges() throws {
        let oldFile = try writeMeeting(folder: "2026-01-01", name: "old", content: fullMeetingMarkdown)
        let newFile = try writeMeeting(folder: "2026-04-10", name: "fresh", content: fullMeetingMarkdown)
        let newBefore = try String(contentsOf: newFile, encoding: .utf8)

        let count = TranscriptExpirySweeper.run(
            baseDirectory: baseDirectory,
            daysToKeep: 30,
            now: localDate("2026-04-16")
        )
        XCTAssertEqual(count.expiredCount, 1)

        let oldAfter = try String(contentsOf: oldFile, encoding: .utf8)
        XCTAssertTrue(oldAfter.contains("<!-- ghost-pepper-transcript-expired:"))

        let newAfter = try String(contentsOf: newFile, encoding: .utf8)
        XCTAssertEqual(newAfter, newBefore)
    }
}
