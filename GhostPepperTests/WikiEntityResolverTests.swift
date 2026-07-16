import XCTest
@testable import GhostPepper

final class WikiEntityResolverTests: XCTestCase {
    private let snapshot: [String: [String]] = [
        "Alpha Person": ["Alpha P.", "alpha.person@example.test"],
        "Alpha Contact": [],
        "Beta Person": ["Beta"],
        "Gamma Person": [],
    ]

    func testExactCanonicalMatch() {
        XCTAssertEqual(
            WikiEntityResolver.resolve(name: "Alpha Person", snapshot: snapshot),
            .matched("Alpha Person")
        )
    }

    func testCaseAndDiacriticsInsensitive() {
        XCTAssertEqual(
            WikiEntityResolver.resolve(name: "alpha person", snapshot: snapshot),
            .matched("Alpha Person")
        )
        XCTAssertEqual(
            WikiEntityResolver.resolve(name: "Gámmá Pérsón", snapshot: snapshot),
            .matched("Gamma Person")
        )
    }

    func testAliasMatch() {
        XCTAssertEqual(
            WikiEntityResolver.resolve(name: "alpha.person@example.test", snapshot: snapshot),
            .matched("Alpha Person")
        )
    }

    func testBareFirstNameWithMultipleCandidatesIsAmbiguous() {
        // "Alpha" token-matches both Alpha Person and Alpha Contact.
        XCTAssertEqual(
            WikiEntityResolver.resolve(name: "Alpha", snapshot: snapshot),
            .ambiguous(["Alpha Contact", "Alpha Person"])
        )
    }

    func testBareNameWithSingleCandidateMatches() {
        XCTAssertEqual(
            WikiEntityResolver.resolve(name: "Gamma", snapshot: snapshot),
            .matched("Gamma Person")
        )
    }

    func testLastNameMatches() {
        XCTAssertEqual(
            WikiEntityResolver.resolve(name: "Person", snapshot: snapshot),
            .ambiguous(["Alpha Person", "Beta Person", "Gamma Person"])
        )
    }

    func testSmallTypoMatches() {
        XCTAssertEqual(
            WikiEntityResolver.resolve(name: "Alpha Persno", snapshot: snapshot),
            .matched("Alpha Person")
        )
    }

    func testUnknownNameIsNew() {
        XCTAssertEqual(
            WikiEntityResolver.resolve(name: "Unlisted Person", snapshot: snapshot),
            .new
        )
    }

    func testEmptyAndTrivialNamesAreNew() {
        XCTAssertEqual(WikiEntityResolver.resolve(name: "  ", snapshot: snapshot), .new)
        XCTAssertEqual(WikiEntityResolver.resolve(name: "", snapshot: snapshot), .new)
    }

    func testNormalizeStripsPunctuation() {
        XCTAssertEqual(WikiEntityResolver.normalize("  Dr.  Foo-Bar!  "), "dr foo bar")
    }

    func testEditDistance() {
        XCTAssertEqual(WikiEntityResolver.editDistance("kitten", "sitting"), 3)
        XCTAssertEqual(WikiEntityResolver.editDistance("abc", "abc"), 0)
        XCTAssertEqual(WikiEntityResolver.editDistance("", "abc"), 3)
    }
}
