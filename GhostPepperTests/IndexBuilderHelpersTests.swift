import XCTest
@testable import GhostPepper

final class IndexBuilderHelpersTests: XCTestCase {
    private var saveDir: URL!

    override func setUpWithError() throws {
        saveDir = FileManager.default.temporaryDirectory.appendingPathComponent("IndexBuilderHelpersTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: saveDir)
    }

    func testAllMeetingPathsReturnsRelativePathsSorted() throws {
        try FileManager.default.createDirectory(at: saveDir.appendingPathComponent("2026-04-28"), withIntermediateDirectories: true)
        try "x".write(to: saveDir.appendingPathComponent("2026-04-28/standup.md"), atomically: true, encoding: .utf8)
        try "x".write(to: saveDir.appendingPathComponent("2026-04-28/q2-planning.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: saveDir.appendingPathComponent("2026-04-27"), withIntermediateDirectories: true)
        try "x".write(to: saveDir.appendingPathComponent("2026-04-27/standup.md"), atomically: true, encoding: .utf8)

        let paths = IndexBuilder.allMeetingPaths(in: saveDir)
        XCTAssertEqual(paths, [
            "2026-04-27/standup.md",
            "2026-04-28/q2-planning.md",
            "2026-04-28/standup.md",
        ])
    }

    func testAllMeetingPathsSkipsDotPrefixedFolders() throws {
        try FileManager.default.createDirectory(at: saveDir.appendingPathComponent("2026-04-28"), withIntermediateDirectories: true)
        try "x".write(to: saveDir.appendingPathComponent("2026-04-28/standup.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: saveDir.appendingPathComponent(".indexes/people"), withIntermediateDirectories: true)
        try "x".write(to: saveDir.appendingPathComponent(".indexes/people/john-smith.md"), atomically: true, encoding: .utf8)

        let paths = IndexBuilder.allMeetingPaths(in: saveDir)
        XCTAssertEqual(paths, ["2026-04-28/standup.md"])
    }

    func testIndexingToolDefinitionsContainsAllFour() {
        let tools = IndexBuilder.indexingToolDefinitions()
        let names = Set(tools.map { $0.name })
        XCTAssertEqual(names, Set(["qmd_search", "read_file", "list_dir", "write_file"]))
    }
}
