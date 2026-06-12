import XCTest
@testable import GhostPepper

final class IndexEntryFileTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("IndexEntryFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRoundTripPreservesAllFields() throws {
        let original = IndexEntry(
            kind: .people,
            canonicalName: "John Smith",
            aliases: ["John", "John S.", "jsmith@example.com"],
            sourceMeetings: ["2026-04-28/standup.md", "2026-04-26/q2-planning.md"],
            lastUpdated: Date(timeIntervalSince1970: 1714320000),
            body: "John leads the platform team. Often pairs with [[Lara Chen]].\n"
        )
        let url = tempDir.appendingPathComponent("john-smith.md")
        try IndexEntryFile.write(original, to: url)
        let loaded = try IndexEntryFile.read(from: url)

        XCTAssertEqual(loaded.kind, original.kind)
        XCTAssertEqual(loaded.canonicalName, original.canonicalName)
        XCTAssertEqual(loaded.aliases, original.aliases)
        XCTAssertEqual(loaded.sourceMeetings, original.sourceMeetings)
        XCTAssertEqual(
            ISO8601DateFormatter().string(from: loaded.lastUpdated),
            ISO8601DateFormatter().string(from: original.lastUpdated)
        )
        XCTAssertEqual(loaded.body, original.body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testRoundTripPreservesWikilinksInBody() throws {
        let entry = IndexEntry(
            kind: .people,
            canonicalName: "Lara Chen",
            aliases: [],
            sourceMeetings: [],
            lastUpdated: Date(),
            body: "Mentioned alongside [[John Smith]] and [[Marcus Lee]]."
        )
        let url = tempDir.appendingPathComponent("lara-chen.md")
        try IndexEntryFile.write(entry, to: url)
        let loaded = try IndexEntryFile.read(from: url)
        XCTAssertTrue(loaded.body.contains("[[John Smith]]"))
        XCTAssertTrue(loaded.body.contains("[[Marcus Lee]]"))
    }

    func testRoundTripWithEmptyAliasesAndSources() throws {
        let entry = IndexEntry(
            kind: .people,
            canonicalName: "Solo Person",
            aliases: [],
            sourceMeetings: [],
            lastUpdated: Date(),
            body: "First mention, no aliases."
        )
        let url = tempDir.appendingPathComponent("solo-person.md")
        try IndexEntryFile.write(entry, to: url)
        let loaded = try IndexEntryFile.read(from: url)
        XCTAssertEqual(loaded.aliases, [])
        XCTAssertEqual(loaded.sourceMeetings, [])
    }

    func testRejectsMissingFrontmatter() {
        XCTAssertThrowsError(try IndexEntryFile.parse("# Just a heading\n\nNo frontmatter."))
    }

    func testRejectsUnknownIndexType() {
        let text = """
        ---
        index_type: aliens
        canonical_name: "ET"
        aliases: []
        source_meetings: []
        last_updated: 2026-04-28T15:30:00Z
        ---

        Body
        """
        XCTAssertThrowsError(try IndexEntryFile.parse(text))
    }

    func testQuotesNamesContainingColons() throws {
        let entry = IndexEntry(
            kind: .people,
            canonicalName: "Dr. Foo: The Sequel",
            aliases: [],
            sourceMeetings: [],
            lastUpdated: Date(),
            body: "x"
        )
        let rendered = IndexEntryFile.render(entry)
        XCTAssertTrue(rendered.contains("canonical_name: \"Dr. Foo: The Sequel\""))
        let parsed = try IndexEntryFile.parse(rendered)
        XCTAssertEqual(parsed.canonicalName, "Dr. Foo: The Sequel")
    }
}

final class IndexEntryInlineLinksTests: XCTestCase {
    func testPreprocessLinksBacktickedMeetingMentions() {
        let source = "In `2026-04-28/standup.md`: introduced the deploy pipeline."
        let processed = IndexEntryInlineLinks.preprocess(source)

        XCTAssertEqual(
            processed,
            "In [2026-04-28/standup.md](gp://meeting/2026-04-28/standup.md): introduced the deploy pipeline."
        )
    }

    func testPreprocessPreservesLineSpecInMeetingMentionLabel() {
        let source = "See 2026-04-28/standup.md:71-72 for the original context."
        let processed = IndexEntryInlineLinks.preprocess(source)

        XCTAssertEqual(
            processed,
            "See [2026-04-28/standup.md:71-72](gp://meeting/2026-04-28/standup.md?line=71) for the original context."
        )
    }

    func testPreprocessKeepsPersonWikilinksTappable() {
        let source = "Often works with [[Lara Chen]]."
        let processed = IndexEntryInlineLinks.preprocess(source)

        XCTAssertEqual(
            processed,
            "Often works with [Lara Chen](wikilink://lara-chen)."
        )
    }
}
