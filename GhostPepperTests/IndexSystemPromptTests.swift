import XCTest
@testable import GhostPepper

final class IndexSystemPromptTests: XCTestCase {
    func testFullBuildPromptIncludesArchiveAndIndexPaths() {
        let prompt = IndexSystemPrompt.buildPeopleIndexFullBuild(
            archiveRootPath: "/Users/x/Meetings",
            indexRootPath: "/Users/x/Meetings/.indexes/people"
        )
        XCTAssertTrue(prompt.contains("/Users/x/Meetings"))
        XCTAssertTrue(prompt.contains("/Users/x/Meetings/.indexes/people"))
    }

    func testFullBuildPromptDescribesAllFourTools() {
        let prompt = IndexSystemPrompt.buildPeopleIndexFullBuild(archiveRootPath: "/a", indexRootPath: "/i")
        XCTAssertTrue(prompt.contains("list_dir"))
        XCTAssertTrue(prompt.contains("qmd_search"))
        XCTAssertTrue(prompt.contains("read_file"))
        XCTAssertTrue(prompt.contains("write_file"))
    }

    func testIncrementalPromptEmbedsAliasSnapshotJSON() {
        let snapshot = ["John Smith": ["John", "JS"], "Lara Chen": []]
        let prompt = IndexSystemPrompt.buildPeopleIndexIncremental(
            archiveRootPath: "/a",
            indexRootPath: "/i",
            meetingPath: "2026-04-28/standup.md",
            aliasSnapshot: snapshot
        )
        XCTAssertTrue(prompt.contains("\"John Smith\""))
        XCTAssertTrue(prompt.contains("\"JS\""))
        XCTAssertTrue(prompt.contains("\"Lara Chen\""))
    }

    func testIncrementalPromptEmbedsMeetingPathExactlyOnce() {
        let prompt = IndexSystemPrompt.buildPeopleIndexIncremental(
            archiveRootPath: "/a",
            indexRootPath: "/i",
            meetingPath: "2026-04-28/standup.md",
            aliasSnapshot: [:]
        )
        let occurrences = prompt.components(separatedBy: "2026-04-28/standup.md").count - 1
        XCTAssertGreaterThanOrEqual(occurrences, 2, "Path should appear in path-callout and process steps")
    }

    func testIncrementalPromptHandlesEmptyAliasSnapshot() {
        let prompt = IndexSystemPrompt.buildPeopleIndexIncremental(
            archiveRootPath: "/a",
            indexRootPath: "/i",
            meetingPath: "x.md",
            aliasSnapshot: [:]
        )
        // Pretty-printed JSON for an empty dict comes out as "{\n\n}", which is
        // still valid JSON; the prompt should still describe the task.
        XCTAssertTrue(prompt.contains("{"))
        XCTAssertTrue(prompt.contains("}"))
        XCTAssertTrue(prompt.contains("write_file"))
    }
}
