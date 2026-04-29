import XCTest
import CoreGraphics
@testable import GhostPepper

final class KeyboardLayoutPasteShortcutResolverTests: XCTestCase {
    func testCurrentPasteKeyCodeReturnsMappedKeyForActiveLayout() {
        let layoutData = Data([0x01, 0x02])
        var translatedKeyCodes: [CGKeyCode] = []

        let resolver = KeyboardLayoutPasteShortcutResolver(
            currentLayoutDataProvider: { layoutData },
            keyboardTypeProvider: { 91 },
            translator: { keyCode, receivedLayoutData, keyboardType in
                translatedKeyCodes.append(keyCode)
                XCTAssertEqual(receivedLayoutData, layoutData)
                XCTAssertEqual(keyboardType, 91)
                return keyCode == 7 ? "v" : "d"
            },
            candidateKeyCodes: [9, 7, 2]
        )

        XCTAssertEqual(resolver.currentPasteKeyCode(), 7)
        XCTAssertEqual(translatedKeyCodes, [9, 7])
    }

    func testCurrentPasteKeyCodeReturnsNilWhenNoMatchExists() {
        let resolver = KeyboardLayoutPasteShortcutResolver(
            currentLayoutDataProvider: { Data([0x01]) },
            keyboardTypeProvider: { 40 },
            translator: { _, _, _ in "d" },
            candidateKeyCodes: [2, 7, 9]
        )

        XCTAssertNil(resolver.currentPasteKeyCode())
    }

    func testCurrentPasteKeyCodeReturnsNilWhenLayoutDataIsUnavailable() {
        var translatorCalls = 0
        let resolver = KeyboardLayoutPasteShortcutResolver(
            currentLayoutDataProvider: { nil },
            keyboardTypeProvider: { 40 },
            translator: { _, _, _ in
                translatorCalls += 1
                return "v"
            },
            candidateKeyCodes: [7]
        )

        XCTAssertNil(resolver.currentPasteKeyCode())
        XCTAssertEqual(translatorCalls, 0)
    }

    func testCurrentPasteKeyCodeReturnsNilWhenTranslationIsNotExactLowercaseV() {
        let resolver = KeyboardLayoutPasteShortcutResolver(
            currentLayoutDataProvider: { Data([0x01]) },
            keyboardTypeProvider: { 40 },
            translator: { _, _, _ in "V" },
            candidateKeyCodes: [7]
        )

        XCTAssertNil(resolver.currentPasteKeyCode())
    }
}
