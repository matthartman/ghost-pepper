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
        title: "Speaker One <> Speaker Two"
        date: "2025-01-29"
        ---

        # Speaker One <> Speaker Two

        ## Summary
        Discussion about Quinn Adler and the fund.
        """.write(to: rootDir.appendingPathComponent("2025-01-29/speaker-one-speaker-two.md"), atomically: true, encoding: .utf8)

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

    // MARK: - grep

    func testGrepFindsMatchAcrossArchive() async throws {
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.grep(pattern: "Quinn", path: nil, caseInsensitive: true, maxResults: 50)
        XCTAssertTrue(result.contains("2025-01-29/speaker-one-speaker-two.md:"), "Expected file:line match in output: \(result)")
        XCTAssertTrue(result.contains("2026-01-07/team-standup.md:"), "Expected second-file match in output: \(result)")
    }

    func testGrepRespectsMaxResults() async throws {
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.grep(pattern: "Quinn", path: nil, caseInsensitive: true, maxResults: 1)
        let matchLines = result.split(separator: "\n").filter { $0.contains(".md:") }
        XCTAssertEqual(matchLines.count, 1, "Expected exactly 1 match line, got: \(result)")
        XCTAssertTrue(result.contains("max_results was 1"), "Expected hit-cap meta line: \(result)")
    }

    func testGrepReturnsNoMatchesMessage() async throws {
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.grep(pattern: "definitelynotinanyfile", path: nil, caseInsensitive: false, maxResults: 50)
        XCTAssertTrue(result.contains("No matches found"), result)
    }

    func testGrepRejectsPathOutsideRoot() async {
        let tools = MeetingQATools(root: rootDir)
        do {
            _ = try await tools.grep(pattern: "anything", path: "../outside", caseInsensitive: true, maxResults: 10)
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
        let result = try await tools.readFile(path: "2025-01-29/speaker-one-speaker-two.md", offset: 1, limit: 200)
        XCTAssertTrue(result.hasPrefix("1\t---\n"), "Expected line 1 prefix, got: \(result.prefix(30))")
        XCTAssertTrue(result.contains("2\ttitle: \"Speaker One <> Speaker Two\""), "Expected line 2: \(result)")
        XCTAssertTrue(result.contains("(End of file at line"), "Expected end-of-file footer: \(result)")
    }

    func testReadFileWithOffsetSkipsEarlierLines() async throws {
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.readFile(path: "2025-01-29/speaker-one-speaker-two.md", offset: 5, limit: 1)
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
        XCTAssertTrue(result.contains("speaker-one-speaker-two.md"))
        XCTAssertFalse(result.contains("speaker-one-speaker-two.md/"), "File should not have / suffix: \(result)")
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
