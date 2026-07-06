import XCTest
@testable import GhostPepper

final class MeetingSessionIndexTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func writeMeeting(id: UUID, dateFolder: String, name: String, modified: Date? = nil) throws -> URL {
        let folder = root.appendingPathComponent(dateFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(name).md")
        try "---\nid: \(id.uuidString)\n---\n\n# \(name)\n".write(to: url, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    // MARK: - Frontmatter persistence

    @MainActor
    func testWriteThenParsePreservesSessionID() throws {
        let id = UUID()
        let transcript = MeetingTranscript(meetingName: "Standup", sessionID: id)
        let url = try MeetingMarkdownWriter.write(transcript: transcript, to: root)

        XCTAssertEqual(MeetingHistory.readSessionID(from: url), id)
        XCTAssertEqual(try MeetingMarkdownWriter.parse(from: url).sessionID, id)
    }

    func testReadSessionIDReturnsNilForLegacyFile() throws {
        let folder = root.appendingPathComponent("2026-06-30")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("legacy.md")
        try "# Legacy meeting\n\nNo frontmatter here.".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertNil(MeetingHistory.readSessionID(from: url))
    }

    // MARK: - Index resolution

    func testResolvesRegisteredSession() async throws {
        let id = UUID()
        let url = try writeMeeting(id: id, dateFolder: "2026-06-30", name: "sync")
        let index = MeetingSessionIndex()
        await index.register(sessionID: id, url: url)
        let resolved = await index.resolve(id)
        XCTAssertEqual(resolved, url)
    }

    func testBuildScansFrontmatter() async throws {
        let id = UUID()
        let url = try writeMeeting(id: id, dateFolder: "2026-06-30", name: "scanned")
        let index = MeetingSessionIndex()
        await index.build(from: root)
        let resolved = await index.resolve(id)
        XCTAssertEqual(resolved?.resolvingSymlinksInPath(), url.resolvingSymlinksInPath())
    }

    func testDuplicateIDResolvesToNewestByModificationTime() async throws {
        let id = UUID()
        let older = try writeMeeting(id: id, dateFolder: "2026-06-01", name: "old", modified: Date(timeIntervalSince1970: 1_000_000))
        let newer = try writeMeeting(id: id, dateFolder: "2026-06-02", name: "new", modified: Date(timeIntervalSince1970: 2_000_000))

        let index = MeetingSessionIndex()
        await index.build(from: root)
        let resolved = await index.resolve(id)?.resolvingSymlinksInPath()
        XCTAssertEqual(resolved, newer.resolvingSymlinksInPath())
        XCTAssertNotEqual(resolved, older.resolvingSymlinksInPath())
    }

    func testResolveSkipsDeletedFile() async throws {
        let id = UUID()
        let url = try writeMeeting(id: id, dateFolder: "2026-06-30", name: "gone")
        let index = MeetingSessionIndex()
        await index.register(sessionID: id, url: url)
        try FileManager.default.removeItem(at: url)
        let resolved = await index.resolve(id)
        XCTAssertNil(resolved)
    }
}
