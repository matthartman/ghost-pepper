import XCTest
@testable import GhostPepper

final class TextPasterTests: XCTestCase {
    func testSaveAndRestoreClipboard() {
        let paster = TextPaster()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        let saved = paster.saveClipboard()
        XCTAssertNotNil(saved)

        pasteboard.clearContents()
        pasteboard.setString("new content", forType: .string)

        paster.restoreClipboard(saved!)
        XCTAssertEqual(pasteboard.string(forType: .string), "original content")
    }

    func testPasteCapturesSessionAfterPasteDelay() {
        var currentSnapshot = "before paste"
        let expectation = expectation(description: "paste session captured")
        let paster = TextPaster { text, date in
            PasteSession(
                pastedText: text,
                pastedAt: date,
                frontmostAppBundleIdentifier: "com.example.app",
                frontmostWindowID: 42,
                frontmostWindowFrame: nil,
                focusedElementFrame: nil,
                focusedElementText: currentSnapshot
            )
        }
        paster.onPaste = { session in
            XCTAssertEqual(session.focusedElementText, "after paste")
            expectation.fulfill()
        }

        paster.paste(text: "Jesse")
        currentSnapshot = "after paste"

        wait(for: [expectation], timeout: 1)
    }
}
