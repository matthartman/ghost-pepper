import XCTest
@testable import GhostPepper

final class KeyChordTests: XCTestCase {
    func testPhysicalKeyUsesRawKeyCodesForSideSpecificKeys() {
        let rightCommand = PhysicalKey(keyCode: 54)
        let leftCommand = PhysicalKey(keyCode: 55)

        XCTAssertNotEqual(rightCommand, leftCommand)
        XCTAssertEqual(rightCommand.keyCode, 54)
        XCTAssertEqual(leftCommand.keyCode, 55)
    }

    func testKeyChordPreservesSideSpecificModifiers() {
        let chord = KeyChord(keys: Set([
            PhysicalKey(keyCode: 54),
            PhysicalKey(keyCode: 61),
            PhysicalKey(keyCode: 49)
        ]))

        XCTAssertEqual(chord?.keys, Set([
            PhysicalKey(keyCode: 54),
            PhysicalKey(keyCode: 61),
            PhysicalKey(keyCode: 49)
        ]))
    }

    func testKeyChordRejectsEmptyChord() {
        XCTAssertNil(KeyChord(keys: []))
    }

    func testKeyChordDecodingRejectsEmptyChord() {
        let data = #"{"keys":[]}"#.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(KeyChord.self, from: data))
    }

    func testKeyChordDisplayStringUsesReadableKeyNames() throws {
        let chord = try XCTUnwrap(KeyChord(keys: Set([
            PhysicalKey(keyCode: 54),
            PhysicalKey(keyCode: 61),
            PhysicalKey(keyCode: 49)
        ])))

        XCTAssertEqual(chord.displayString, "Right Command + Right Option + Space")
    }

    func testKeyChordShortcutRecorderDisplayStringUsesSymbolsWithSideSuffixes() throws {
        let chord = try XCTUnwrap(KeyChord(keys: Set([
            PhysicalKey(keyCode: 54),
            PhysicalKey(keyCode: 61),
            PhysicalKey(keyCode: 49)
        ])))

        XCTAssertEqual(chord.shortcutRecorderDisplayString, "⌘ʳ + ⌥ʳ + Space")
    }
}
