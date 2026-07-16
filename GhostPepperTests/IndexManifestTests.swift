import XCTest
@testable import GhostPepper

final class IndexManifestTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("IndexManifestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testEmptyManifestHasCurrentVersionAndNoProcessedMeetings() {
        let manifest = IndexManifest.empty(kind: .people)
        XCTAssertEqual(manifest.version, IndexManifest.currentVersion)
        XCTAssertEqual(manifest.kind, .people)
        XCTAssertTrue(manifest.processedMeetings.isEmpty)
    }

    func testIsProcessedReflectsMarkProcessed() {
        var manifest = IndexManifest.empty(kind: .people)
        XCTAssertFalse(manifest.isProcessed(meetingPath: "2026-04-28/standup.md"))
        manifest.markProcessed(meetingPath: "2026-04-28/standup.md", entriesTouched: ["john-smith.md"])
        XCTAssertTrue(manifest.isProcessed(meetingPath: "2026-04-28/standup.md"))
        XCTAssertEqual(manifest.processedMeetings["2026-04-28/standup.md"]?.entriesTouched, ["john-smith.md"])
    }

    func testRoundTripThroughDisk() throws {
        var manifest = IndexManifest.empty(kind: .people)
        // Pin builtAt to an integer-second date; the ISO8601 encoder drops fractional seconds,
        // and Date() from .empty includes sub-millisecond precision that won't round-trip.
        manifest.builtAt = Date(timeIntervalSince1970: 1714000000)
        manifest.markProcessed(
            meetingPath: "2026-04-28/standup.md",
            entriesTouched: ["john-smith.md", "lara-chen.md"],
            at: Date(timeIntervalSince1970: 1714320000)
        )
        let url = tempDir.appendingPathComponent("_manifest.json")
        try manifest.save(to: url)

        let loaded = try IndexManifest.load(from: url)
        XCTAssertEqual(loaded, manifest)
    }

    func testLoadOrEmptyReturnsEmptyWhenFileMissing() {
        let url = tempDir.appendingPathComponent("nope.json")
        let loaded = IndexManifest.loadOrEmpty(at: url, kind: .people)
        XCTAssertEqual(loaded.processedMeetings, [:])
        XCTAssertEqual(loaded.kind, .people)
    }

    func testJSONUsesSnakeCaseKeys() throws {
        var manifest = IndexManifest.empty(kind: .people)
        manifest.markProcessed(meetingPath: "x.md", entriesTouched: ["y.md"])
        let url = tempDir.appendingPathComponent("_manifest.json")
        try manifest.save(to: url)
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(json.contains("\"processed_meetings\""))
        XCTAssertTrue(json.contains("\"built_at\""))
        XCTAssertTrue(json.contains("\"processed_at\""))
        XCTAssertTrue(json.contains("\"entries_touched\""))
    }

    func testAliasSnapshotReadsExistingEntryFiles() throws {
        let saveDir = tempDir!
        let indexRoot = MarkdownArchivePaths.indexRoot(in: saveDir, kind: .people)
        try FileManager.default.createDirectory(at: indexRoot, withIntermediateDirectories: true)

        try IndexEntryFile.write(
            IndexEntry(kind: .people, canonicalName: "John Smith", aliases: ["John", "JS"], sourceMeetings: [], lastUpdated: Date(), body: ""),
            to: MarkdownArchivePaths.entryURL(in: saveDir, kind: .people, slug: "john-smith")
        )
        try IndexEntryFile.write(
            IndexEntry(kind: .people, canonicalName: "Jordan Pike", aliases: [], sourceMeetings: [], lastUpdated: Date(), body: ""),
            to: MarkdownArchivePaths.entryURL(in: saveDir, kind: .people, slug: "jordan-pike")
        )
        // Manifest file should be ignored even though it lives in the same dir.
        let manifestPlaceholder = MarkdownArchivePaths.manifestURL(in: saveDir, kind: .people)
        try "{}".write(to: manifestPlaceholder, atomically: true, encoding: .utf8)

        let snapshot = IndexManifest.aliasSnapshot(in: saveDir, kind: .people)
        XCTAssertEqual(snapshot["John Smith"], ["John", "JS"])
        XCTAssertEqual(snapshot["Jordan Pike"], [])
        XCTAssertEqual(snapshot.count, 2, "manifest file should be skipped")
    }
}
