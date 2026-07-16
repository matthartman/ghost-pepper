import XCTest
@testable import GhostPepper

final class QMDServiceTests: XCTestCase {
    private var tempDir: URL!
    private var service: QMDService!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QMDServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        service = QMDService(archiveRoot: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - JSON parsing (defensive across plausible qmd output shapes)

    func testParsesTopLevelArray() {
        let json = """
        [{"path": "2026-04-28/standup.md", "snippet": "the fund closed", "score": 0.82}]
        """
        let hits = QMDService.parseHits(fromJSON: json)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].path, "2026-04-28/standup.md")
        XCTAssertEqual(hits[0].score, 0.82)
    }

    func testParsesWrappedResults() {
        let json = """
        {"results": [{"file": "a.md", "text": "hello", "relevance": "0.5"}]}
        """
        let hits = QMDService.parseHits(fromJSON: json)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].path, "a.md")
        XCTAssertEqual(hits[0].snippet, "hello")
        XCTAssertEqual(hits[0].score, 0.5)
    }

    func testParsesLineFieldWhenPresent() {
        let json = """
        {"hits": [{"filepath": "b.md", "content": "x", "line_start": 42}]}
        """
        let hits = QMDService.parseHits(fromJSON: json)
        XCTAssertEqual(hits[0].startLine, 42)
    }

    func testSkipsItemsWithoutPath() {
        let json = """
        [{"snippet": "orphan"}, {"path": "ok.md", "snippet": "fine"}]
        """
        XCTAssertEqual(QMDService.parseHits(fromJSON: json).count, 1)
    }

    func testGarbageInputYieldsEmpty() {
        XCTAssertTrue(QMDService.parseHits(fromJSON: "not json at all").isEmpty)
        XCTAssertTrue(QMDService.parseHits(fromJSON: "").isEmpty)
    }

    // MARK: - Snippet → line mapping

    func testMapToLinesFindsSnippetInFile() throws {
        let folder = tempDir.appendingPathComponent("2026-04-28")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("standup.md")
        let content = (1...50).map { "line number \($0) content" }.joined(separator: "\n")
            .replacingOccurrences(of: "line number 30 content", with: "the fund closed at forty million dollars")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let hit = QMDService.Hit(
            path: "2026-04-28/standup.md",
            snippet: "the fund closed at forty million dollars\nline number 31 content",
            score: 0.9,
            startLine: nil,
            endLine: nil
        )
        let mapped = service.mapToLines(hit)
        XCTAssertEqual(mapped.startLine, 30)
        XCTAssertEqual(mapped.endLine, 31)
    }

    func testMapToLinesRebasesAbsolutePath() {
        let hit = QMDService.Hit(
            path: tempDir.standardizedFileURL.path + "/2026-04-28/x.md",
            snippet: "",
            score: nil,
            startLine: 5,
            endLine: nil
        )
        let mapped = service.mapToLines(hit)
        XCTAssertEqual(mapped.path, "2026-04-28/x.md")
    }

    // MARK: - Tool-result formatting

    func testFormatHitsIsGrepShaped() {
        let hits = [
            QMDService.Hit(path: "2026-04-28/standup.md", snippet: "the fund closed", score: 0.82, startLine: 30, endLine: 31),
            QMDService.Hit(path: "2026-05-01/sync.md", snippet: "another match", score: nil, startLine: nil, endLine: nil),
        ]
        let out = QMDService.formatHits(hits, query: "fund close")
        XCTAssertTrue(out.contains("2026-04-28/standup.md:30-31 (score 0.82)"))
        XCTAssertTrue(out.contains("\n--\n"))
        XCTAssertTrue(out.contains("2 results"))
    }

    func testFormatEmptyHitsSuggestsFallback() {
        let out = QMDService.formatHits([], query: "nothing")
        XCTAssertTrue(out.contains("No results"))
        XCTAssertTrue(out.lowercased().contains("grep"))
    }

    func testCollectionNameIsStablePerArchive() {
        let again = QMDService(archiveRoot: tempDir)
        XCTAssertEqual(service.collectionName, again.collectionName)
        XCTAssertTrue(service.collectionName.hasPrefix("ghostpepper-"))

        let other = QMDService(archiveRoot: tempDir.appendingPathComponent("elsewhere"))
        XCTAssertNotEqual(service.collectionName, other.collectionName)
    }
}
