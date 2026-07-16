import XCTest
@testable import GhostPepper

final class MarkdownArchivePathsTests: XCTestCase {
    func testIndexRootIsDotIndexesPlusKindSubdir() {
        let saveDir = URL(fileURLWithPath: "/tmp/whispercat-test")
        let url = MarkdownArchivePaths.indexRoot(in: saveDir, kind: .people)
        XCTAssertEqual(url.path, "/tmp/whispercat-test/.indexes/people")
    }

    func testManifestURLEndsInUnderscoreManifestJSON() {
        let saveDir = URL(fileURLWithPath: "/tmp/whispercat-test")
        let url = MarkdownArchivePaths.manifestURL(in: saveDir, kind: .people)
        XCTAssertEqual(url.lastPathComponent, "_manifest.json")
        XCTAssertTrue(url.path.hasSuffix("/.indexes/people/_manifest.json"))
    }

    func testEntryURLAppendsSlugDotMD() {
        let saveDir = URL(fileURLWithPath: "/tmp/whispercat-test")
        let url = MarkdownArchivePaths.entryURL(in: saveDir, kind: .people, slug: "john-smith")
        XCTAssertEqual(url.lastPathComponent, "john-smith.md")
    }

    func testSlugifyBasicLowercasesAndReplacesSpaces() {
        XCTAssertEqual(MarkdownArchivePaths.slugForIndexEntry("John Smith"), "john-smith")
    }

    func testSlugifyStripsPunctuation() {
        XCTAssertEqual(MarkdownArchivePaths.slugForIndexEntry("Jordan Pike (eng)"), "jordan-pike-eng")
    }

    func testSlugifyCollapsesRepeatedDashes() {
        XCTAssertEqual(MarkdownArchivePaths.slugForIndexEntry("A!!!B"), "a-b")
    }

    func testSlugifyReturnsUntitledForEmptyOrAllPunctuation() {
        XCTAssertEqual(MarkdownArchivePaths.slugForIndexEntry(""), "untitled")
        XCTAssertEqual(MarkdownArchivePaths.slugForIndexEntry("!!!"), "untitled")
    }

    func testSlugifyCapsAt60Chars() {
        let longName = String(repeating: "a", count: 100)
        XCTAssertEqual(MarkdownArchivePaths.slugForIndexEntry(longName).count, 60)
    }
}
