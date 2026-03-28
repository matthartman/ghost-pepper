import XCTest
import ApplicationServices
@testable import GhostPepper

final class TextPasterTests: XCTestCase {
    func testContainsLikelyPasteTargetAcceptsTerminalStyleFocusedTextArea() {
        let snapshot = TextPaster.AccessibilitySnapshot(
            role: kAXTextAreaRole as String,
            isEnabled: nil,
            isEditable: nil,
            isFocused: true,
            hasSelectedTextRange: true,
            valueIsSettable: false
        )

        XCTAssertTrue(TextPaster.containsLikelyPasteTarget(startingAt: snapshot))
    }

    func testContainsLikelyPasteTargetAcceptsWindowWithFocusedTextDescendant() {
        let snapshot = TextPaster.AccessibilitySnapshot(
            role: kAXWindowRole as String,
            isEnabled: true,
            isEditable: nil,
            isFocused: false,
            hasSelectedTextRange: false,
            valueIsSettable: false,
            children: [
                TextPaster.AccessibilitySnapshot(
                    role: kAXGroupRole as String,
                    isEnabled: nil,
                    isEditable: nil,
                    isFocused: false,
                    hasSelectedTextRange: false,
                    valueIsSettable: false,
                    children: [
                        TextPaster.AccessibilitySnapshot(
                            role: kAXTextAreaRole as String,
                            isEnabled: nil,
                            isEditable: nil,
                            isFocused: true,
                            hasSelectedTextRange: true,
                            valueIsSettable: false
                        )
                    ]
                )
            ]
        )

        XCTAssertTrue(TextPaster.containsLikelyPasteTarget(startingAt: snapshot))
    }

    func testContainsLikelyPasteTargetRejectsCodexStyleGroupedWindowWithoutFocusedInput() {
        let snapshot = TextPaster.AccessibilitySnapshot(
            role: kAXWindowRole as String,
            isEnabled: true,
            isEditable: nil,
            isFocused: false,
            hasSelectedTextRange: false,
            valueIsSettable: false,
            children: [
                TextPaster.AccessibilitySnapshot(
                    role: kAXGroupRole as String,
                    isEnabled: nil,
                    isEditable: nil,
                    isFocused: false,
                    hasSelectedTextRange: true,
                    valueIsSettable: false,
                    children: [
                        TextPaster.AccessibilitySnapshot(
                            role: kAXGroupRole as String,
                            isEnabled: nil,
                            isEditable: nil,
                            isFocused: false,
                            hasSelectedTextRange: true,
                            valueIsSettable: false
                        )
                    ]
                )
            ]
        )

        XCTAssertFalse(TextPaster.containsLikelyPasteTarget(startingAt: snapshot))
    }

    func testContainsLikelyPasteTargetAcceptsCodexStyleGroupedEditorWithSettableValue() {
        let snapshot = TextPaster.AccessibilitySnapshot(
            role: kAXWindowRole as String,
            isEnabled: true,
            isEditable: nil,
            isFocused: false,
            hasSelectedTextRange: false,
            valueIsSettable: false,
            children: [
                TextPaster.AccessibilitySnapshot(
                    role: kAXGroupRole as String,
                    isEnabled: true,
                    isEditable: nil,
                    isFocused: false,
                    hasSelectedTextRange: true,
                    valueIsSettable: true,
                    children: [
                        TextPaster.AccessibilitySnapshot(
                            role: kAXGroupRole as String,
                            isEnabled: true,
                            isEditable: nil,
                            isFocused: false,
                            hasSelectedTextRange: true,
                            valueIsSettable: true
                        )
                    ]
                )
            ]
        )

        XCTAssertTrue(TextPaster.containsLikelyPasteTarget(startingAt: snapshot))
    }

    func testContainsLikelyPasteTargetRejectsWindowWithoutEditableSignals() {
        let snapshot = TextPaster.AccessibilitySnapshot(
            role: kAXWindowRole as String,
            isEnabled: true,
            isEditable: nil,
            isFocused: false,
            hasSelectedTextRange: false,
            valueIsSettable: false,
            children: [
                TextPaster.AccessibilitySnapshot(
                    role: kAXButtonRole as String,
                    isEnabled: true,
                    isEditable: nil,
                    isFocused: false,
                    hasSelectedTextRange: false,
                    valueIsSettable: false
                )
            ]
        )

        XCTAssertFalse(TextPaster.containsLikelyPasteTarget(startingAt: snapshot))
    }

    func testSaveAndRestoreClipboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        let paster = TextPaster(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        let saved = paster.saveClipboard()
        XCTAssertNotNil(saved)

        pasteboard.clearContents()
        pasteboard.setString("new content", forType: .string)

        paster.restoreClipboard(saved!)
        XCTAssertEqual(pasteboard.string(forType: .string), "original content")

        pasteboard.releaseGlobally()
    }

    func testPasteLeavesTranscriptOnClipboardWhenFocusedInputIsUnavailable() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        var scheduledActions = 0
        let paster = TextPaster(
            pasteboard: pasteboard,
            canPasteIntoFocusedElement: { false },
            prepareCommandV: {
                XCTFail("prepareCommandV should not be called when no focused input is available")
                return nil
            },
            schedule: { _, _ in
                scheduledActions += 1
            }
        )

        let result = paster.paste(text: "new content")

        XCTAssertEqual(result, .copiedToClipboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "new content")
        XCTAssertEqual(scheduledActions, 0)

        pasteboard.releaseGlobally()
    }

    func testPasteSchedulesCommandVAndRestoresClipboardWhenFocusedInputIsAvailable() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        var scheduledActions: [() -> Void] = []
        var postedCommandV = 0
        let paster = TextPaster(
            pasteboard: pasteboard,
            canPasteIntoFocusedElement: { true },
            prepareCommandV: {
                { postedCommandV += 1 }
            },
            schedule: { _, action in
                scheduledActions.append(action)
            }
        )

        let result = paster.paste(text: "new content")

        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(pasteboard.string(forType: .string), "new content")
        XCTAssertEqual(postedCommandV, 0)
        XCTAssertEqual(scheduledActions.count, 1)

        let postPasteAction = scheduledActions.removeFirst()
        postPasteAction()

        XCTAssertEqual(postedCommandV, 1)
        XCTAssertEqual(scheduledActions.count, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "new content")

        let restoreClipboardAction = scheduledActions.removeFirst()
        restoreClipboardAction()

        XCTAssertEqual(pasteboard.string(forType: .string), "original content")

        pasteboard.releaseGlobally()
    }

    func testPasteCapturesSessionAfterPasteDelay() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        var currentSnapshot = "before paste"
        var scheduledActions: [() -> Void] = []
        let expectation = expectation(description: "paste session captured")
        let paster = TextPaster(
            pasteboard: pasteboard,
            canPasteIntoFocusedElement: { true },
            prepareCommandV: { {} },
            pasteSessionProvider: { text, date in
            PasteSession(
                pastedText: text,
                pastedAt: date,
                frontmostAppBundleIdentifier: "com.example.app",
                frontmostWindowID: 42,
                frontmostWindowFrame: nil,
                focusedElementFrame: nil,
                focusedElementText: currentSnapshot
            )
            },
            schedule: { _, action in
                scheduledActions.append(action)
            }
        )
        paster.onPaste = { session in
            XCTAssertEqual(session.focusedElementText, "after paste")
            expectation.fulfill()
        }

        let result = paster.paste(text: "Jesse")
        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(scheduledActions.count, 1)

        currentSnapshot = "after paste"

        let postPasteAction = scheduledActions.removeFirst()
        postPasteAction()

        XCTAssertEqual(scheduledActions.count, 1)

        let captureSessionAction = scheduledActions.removeFirst()
        captureSessionAction()

        wait(for: [expectation], timeout: 1)
        pasteboard.releaseGlobally()
    }
}
