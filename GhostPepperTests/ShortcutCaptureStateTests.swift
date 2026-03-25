import XCTest
@testable import GhostPepper

final class ShortcutCaptureStateTests: XCTestCase {
    private let rightCommand = PhysicalKey(keyCode: 54)
    private let rightOption = PhysicalKey(keyCode: 61)
    private let space = PhysicalKey(keyCode: 49)

    func testCaptureStateCommitsChordAfterReleasingPrefixModifiers() throws {
        var state = ShortcutCaptureState()

        XCTAssertNil(state.handle(.flagsChanged(rightCommand)))
        XCTAssertNil(state.handle(.flagsChanged(rightOption)))
        XCTAssertNil(state.handle(.keyDown(space)))
        XCTAssertNil(state.handle(.keyUp(space)))
        XCTAssertNil(state.handle(.flagsChanged(rightOption)))
        let chord = try XCTUnwrap(state.handle(.flagsChanged(rightCommand)))

        XCTAssertEqual(
            chord,
            try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption, space])))
        )
        XCTAssertTrue(state.pressedKeys.isEmpty)
        XCTAssertTrue(state.capturedKeys.isEmpty)
    }
}
