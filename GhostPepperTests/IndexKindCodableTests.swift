import XCTest
@testable import GhostPepper

/// The IndexKind enum → struct refactor must keep on-disk encodings
/// byte-compatible: bare strings in JSON, same rawValues, same equality.
final class IndexKindCodableTests: XCTestCase {
    func testEncodesAsBareString() throws {
        let data = try JSONEncoder().encode([IndexKind.people])
        XCTAssertEqual(String(data: data, encoding: .utf8), "[\"people\"]")
    }

    func testDecodesFromBareString() throws {
        let decoded = try JSONDecoder().decode([IndexKind].self, from: Data("[\"people\"]".utf8))
        XCTAssertEqual(decoded, [.people])
    }

    func testDecodesUnknownSlugAndFallsBackForDisplay() throws {
        let decoded = try JSONDecoder().decode(IndexKind.self, from: Data("\"widgets\"".utf8))
        XCTAssertEqual(decoded.rawValue, "widgets")
        // Unknown slug renders via the fallback spec instead of crashing.
        XCTAssertEqual(decoded.displayName, "Widgets")
        XCTAssertEqual(decoded.iconSystemName, "folder")
    }

    func testManifestJSONStaysCompatible() throws {
        let json = """
        {"version": 1, "kind": "people", "built_at": "2026-04-28T15:30:00Z", "processed_meetings": {}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(IndexManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.kind, .people)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let reencoded = try encoder.encode(manifest)
        XCTAssertTrue(String(data: reencoded, encoding: .utf8)!.contains("\"kind\":\"people\""))
    }

    func testSwitchPatternMatchingStillWorks() {
        let kind = IndexKind(rawValue: "people")
        switch kind {
        case .people:
            break  // expected
        default:
            XCTFail("static-member pattern matching should hit .people")
        }
    }

    func testPeopleAlwaysFirstInAllCases() {
        XCTAssertEqual(IndexKind.allCases.first, .people)
    }
}
