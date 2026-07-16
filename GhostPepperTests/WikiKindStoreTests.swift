import XCTest
@testable import GhostPepper

final class WikiKindStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: WikiKindStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WikiKindStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dir = tempDir!
        store = WikiKindStore(saveDirResolver: { dir })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func companiesSpec() -> WikiKindSpec {
        WikiKindSpec(
            slug: "companies",
            displayName: "Companies",
            entityNoun: "company",
            iconSystemName: "building.2",
            extractionHint: "A named business or startup.",
            createdAt: Date()
        )
    }

    func testPeopleAlwaysPresentAndFirst() {
        XCTAssertEqual(store.allKinds.first?.slug, "people")
        XCTAssertEqual(store.allKinds.count, 1)
    }

    func testAddKindPersistsAndRoundtrips() throws {
        try store.addKind(companiesSpec())
        XCTAssertEqual(store.allKinds.map { $0.slug }, ["people", "companies"])

        // A fresh store instance reads the same registry from disk.
        let dir = tempDir!
        let reloaded = WikiKindStore(saveDirResolver: { dir })
        XCTAssertEqual(reloaded.allKinds.map { $0.slug }, ["people", "companies"])
        XCTAssertEqual(reloaded.spec(for: "companies").entityNoun, "company")
    }

    func testAddKindCreatesIndexDirectory() throws {
        try store.addKind(companiesSpec())
        let root = MarkdownArchivePaths.indexesRoot(in: tempDir).appendingPathComponent("companies")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testDuplicateSlugRejected() throws {
        try store.addKind(companiesSpec())
        XCTAssertThrowsError(try store.addKind(companiesSpec()))
    }

    func testPeopleSlugRejected() {
        var spec = companiesSpec()
        spec.slug = "people"
        spec.displayName = "People"
        XCTAssertThrowsError(try store.addKind(spec))
    }

    func testIconCoercedToAllowedSet() throws {
        var spec = companiesSpec()
        spec.iconSystemName = "totally.made.up.symbol"
        try store.addKind(spec)
        XCTAssertEqual(store.spec(for: "companies").iconSystemName, "folder")
    }

    func testUnknownSlugFallsBack() {
        let spec = store.spec(for: "long-lost-kind")
        XCTAssertEqual(spec.displayName, "Long Lost Kind")
        XCTAssertEqual(spec.iconSystemName, "folder")
    }

    func testProposalsRoundtripAndDismiss() {
        let proposal = WikiKindProposal(spec: companiesSpec(), rationale: "12 recurring companies", proposedAt: Date())
        store.saveProposals([proposal])
        XCTAssertEqual(store.proposals.map { $0.spec.slug }, ["companies"])

        store.removeProposal(slug: "companies")
        XCTAssertTrue(store.proposals.isEmpty)
    }

    func testProposalMatchingExistingKindIsDropped() throws {
        try store.addKind(companiesSpec())
        let proposal = WikiKindProposal(spec: companiesSpec(), rationale: "dupe", proposedAt: Date())
        store.saveProposals([proposal])
        XCTAssertTrue(store.proposals.isEmpty)
    }

    func testRemoveKindKeepsEntriesOnDisk() throws {
        try store.addKind(companiesSpec())
        let root = MarkdownArchivePaths.indexesRoot(in: tempDir).appendingPathComponent("companies")
        let entry = root.appendingPathComponent("acme.md")
        try "---\nindex_type: companies\ncanonical_name: Acme\n---\n\nbody\n".write(to: entry, atomically: true, encoding: .utf8)

        try store.removeKind(slug: "companies")
        XCTAssertEqual(store.allKinds.map { $0.slug }, ["people"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.path))
    }
}
