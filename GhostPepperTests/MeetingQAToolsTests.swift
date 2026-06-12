import XCTest
@testable import GhostPepper

final class MeetingQAToolsTests: XCTestCase {
    private var rootDir: URL!

    override func setUpWithError() throws {
        rootDir = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingQAToolsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir.appendingPathComponent("2025-01-29"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootDir.appendingPathComponent("2026-01-07"), withIntermediateDirectories: true)
        try """
        ---
        title: "Dana <> Matt"
        date: "2025-01-29"
        ---

        # Dana <> Matt

        ## Summary
        Discussion about Quinn Adler and the fund.
        """.write(to: rootDir.appendingPathComponent("2025-01-29/dana-matt.md"), atomically: true, encoding: .utf8)

        try """
        # team-standup

        **Date:** 2026-01-07

        ## Notes
        Sam Rivers - he's not a Quinn Adler for 10 years. Trade ideas.
        """.write(to: rootDir.appendingPathComponent("2026-01-07/team-standup.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootDir)
    }

    // MARK: - qmd_search

    func testQMDSearchFindsMatchAcrossArchive() async throws {
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.qmdSearch(query: "Quinn", path: nil, caseInsensitive: true, maxResults: 50)
        XCTAssertTrue(result.contains("2025-01-29/dana-matt.md:"), "Expected file:line match in output: \(result)")
        XCTAssertTrue(result.contains("2026-01-07/team-standup.md:"), "Expected second-file match in output: \(result)")
    }

    func testQMDSearchOutputContainsCitationReadyContext() async throws {
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.qmdSearch(query: "Sam Rivers", path: nil, caseInsensitive: true, maxResults: 10)
        XCTAssertTrue(result.contains("2026-01-07/team-standup.md:"), "Expected cited match line: \(result)")
        XCTAssertTrue(result.contains("Sam Rivers"), "Expected matched text in output: \(result)")
        XCTAssertFalse(result.contains("2025-01-30: 4,000+ lines"), "Search should return source context, not a generic date-only timeline: \(result)")
    }

    func testQMDSearchStillFindsExactTextWhenQMDIsBypassed() async throws {
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.qmdSearch(query: "\"Sam Rivers\"", path: nil, caseInsensitive: false, maxResults: 10)
        XCTAssertTrue(result.contains("2026-01-07/team-standup.md:"), "Expected pure Swift fallback cited match line: \(result)")
        XCTAssertTrue(result.contains("Sam Rivers"), "Expected matched text in fallback output: \(result)")
    }

    func testLegacyGrepToolAliasStillSearchesArchive() async throws {
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.grep(pattern: "Quinn Adler", path: nil, caseInsensitive: true, maxResults: 10)
        XCTAssertTrue(result.contains("2025-01-29/dana-matt.md:"), "Expected legacy grep alias to return qmd/search-style citations: \(result)")
    }

    func testQMDSearchRespectsMaxResults() async throws {
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.qmdSearch(query: "Quinn", path: nil, caseInsensitive: true, maxResults: 1)
        let matchLines = result.split(separator: "\n").filter { $0.contains(".md:") }
        XCTAssertEqual(matchLines.count, 1, "Expected exactly 1 match line, got: \(result)")
        XCTAssertTrue(result.contains("max_results hit"), "Expected hit-cap meta line: \(result)")
    }

    func testQMDSearchReturnsNoMatchesMessage() async throws {
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.qmdSearch(query: "definitelynotinanyfile", path: nil, caseInsensitive: false, maxResults: 50)
        XCTAssertTrue(result.contains("No matches found"), result)
    }

    func testQMDSearchRejectsPathOutsideRoot() async {
        let tools = MeetingQATools(root: rootDir)
        do {
            _ = try await tools.qmdSearch(query: "anything", path: "../outside", caseInsensitive: true, maxResults: 10)
            XCTFail("Expected pathOutsideRoot error")
        } catch let error as PathSandboxError {
            guard case .pathOutsideRoot = error else { XCTFail("Wrong error: \(error)"); return }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - read_file

    func testReadFileReturnsRequestedSliceWithLineNumbers() async throws {
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.readFile(path: "2025-01-29/dana-matt.md", offset: 1, limit: 200)
        XCTAssertTrue(result.hasPrefix("1\t---\n"), "Expected line 1 prefix, got: \(result.prefix(30))")
        XCTAssertTrue(result.contains("2\ttitle: \"Dana <> Matt\""), "Expected line 2: \(result)")
        XCTAssertTrue(result.contains("(End of file at line"), "Expected end-of-file footer: \(result)")
    }

    func testReadFileWithOffsetSkipsEarlierLines() async throws {
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.readFile(path: "2025-01-29/dana-matt.md", offset: 5, limit: 1)
        let firstLine = result.split(separator: "\n").first ?? ""
        XCTAssertTrue(firstLine.hasPrefix("5\t"), "Expected line 5 prefix, got: \(firstLine)")
    }

    func testReadFilePaginationFooterWhenMoreLinesExist() async throws {
        let big = (1...50).map { "line \($0)" }.joined(separator: "\n")
        let url = rootDir.appendingPathComponent("2025-01-29/big.md")
        try big.write(to: url, atomically: true, encoding: .utf8)
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.readFile(path: "2025-01-29/big.md", offset: 1, limit: 10)
        XCTAssertTrue(result.contains("(Returned lines 1-10 of 50. Use offset=11 to continue.)"), result)
    }

    func testReadFileRejectsPathOutsideRoot() async {
        let tools = MeetingQATools(root: rootDir)
        do {
            _ = try await tools.readFile(path: "../outside.md", offset: 1, limit: 200)
            XCTFail("Expected pathOutsideRoot error")
        } catch is PathSandboxError {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReadFileMissingFileThrows() async {
        let tools = MeetingQATools(root: rootDir)
        do {
            _ = try await tools.readFile(path: "nope.md", offset: 1, limit: 200)
            XCTFail("Expected fileNotFound error")
        } catch let error as MeetingQAToolError {
            guard case .fileNotFound = error else { XCTFail("Wrong error: \(error)"); return }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - list_dir

    func testListDirReturnsSortedEntriesWithDirSuffix() async throws {
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.listDir(path: "")
        let lines = result.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("2025-01-29/"), "Expected dir entry: \(lines)")
        XCTAssertTrue(lines.contains("2026-01-07/"), "Expected dir entry: \(lines)")
        let i25 = lines.firstIndex(of: "2025-01-29/")!
        let i26 = lines.firstIndex(of: "2026-01-07/")!
        XCTAssertLessThan(i25, i26)
    }

    func testListDirInsideDateFolder() async throws {
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.listDir(path: "2025-01-29")
        XCTAssertTrue(result.contains("dana-matt.md"))
        XCTAssertFalse(result.contains("dana-matt.md/"), "File should not have / suffix: \(result)")
    }

    func testListDirRejectsPathOutsideRoot() async {
        let tools = MeetingQATools(root: rootDir)
        do {
            _ = try await tools.listDir(path: "../outside")
            XCTFail("Expected pathOutsideRoot error")
        } catch is PathSandboxError {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testListDirOnMissingDirThrows() async {
        let tools = MeetingQATools(root: rootDir)
        do {
            _ = try await tools.listDir(path: "nope")
            XCTFail("Expected notADirectory error")
        } catch let error as MeetingQAToolError {
            guard case .notADirectory = error else { XCTFail("Wrong error: \(error)"); return }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
