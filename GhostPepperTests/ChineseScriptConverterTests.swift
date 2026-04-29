import XCTest
@testable import GhostPepper

final class ChineseScriptConverterTests: XCTestCase {
    func testAutoPreferenceLeavesTextUnchanged() {
        let traditional = "你到底有沒有在聽我講"
        XCTAssertEqual(ChineseScriptConverter.convert(traditional, to: .auto), traditional)
    }

    func testSimplifiedConvertsTraditionalInput() {
        // Issue #68 reproducer
        let traditional = "你到底有沒有在聽我講"
        let simplified = ChineseScriptConverter.convert(traditional, to: .simplified)
        XCTAssertEqual(simplified, "你到底有没有在听我讲")
    }

    func testTraditionalConvertsSimplifiedInput() {
        let simplified = "你到底有没有在听我讲"
        let traditional = ChineseScriptConverter.convert(simplified, to: .traditional)
        XCTAssertEqual(traditional, "你到底有沒有在聽我講")
    }

    func testNonChineseTextIsUntouched() {
        let english = "Hello, world."
        XCTAssertEqual(ChineseScriptConverter.convert(english, to: .simplified), english)
        XCTAssertEqual(ChineseScriptConverter.convert(english, to: .traditional), english)
    }

    func testEmptyStringRoundTrips() {
        XCTAssertEqual(ChineseScriptConverter.convert("", to: .simplified), "")
    }
}
