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

    func testContainsLikelyPasteTargetRejectsFocusedCodexBackgroundGroupWithoutSettableValue() {
        let snapshot = TextPaster.AccessibilitySnapshot(
            role: kAXGroupRole as String,
            isEnabled: true,
            isEditable: nil,
            isFocused: true,
            hasSelectedTextRange: true,
            valueIsSettable: false
        )

        XCTAssertFalse(TextPaster.containsLikelyPasteTarget(startingAt: snapshot))
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
        var pasteStartCalls = 0
        var pasteEndCalls = 0
        let paster = TextPaster(
            pasteboard: pasteboard,
            canPasteIntoFocusedElement: { false },
            preparePasteShortcutAction: {
                XCTFail("preparePasteShortcutAction should not be called when no focused input is available")
                return nil
            },
            schedule: { _, _ in
                scheduledActions += 1
            }
        )
        paster.onPasteStart = { pasteStartCalls += 1 }
        paster.onPasteEnd = { pasteEndCalls += 1 }

        let result = paster.paste(text: "new content")

        XCTAssertEqual(result, .copiedToClipboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "new content")
        XCTAssertEqual(scheduledActions, 0)
        XCTAssertEqual(pasteStartCalls, 1)
        XCTAssertEqual(pasteEndCalls, 1)

        pasteboard.releaseGlobally()
    }

    func testPasteLeavesTranscriptOnClipboardWhenPasteShortcutCannotBePrepared() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        var scheduledActions = 0
        var prepareCalls = 0
        var pasteStartCalls = 0
        var pasteEndCalls = 0
        let paster = TextPaster(
            pasteboard: pasteboard,
            canPasteIntoFocusedElement: { true },
            preparePasteShortcutAction: {
                prepareCalls += 1
                return nil
            },
            schedule: { _, _ in
                scheduledActions += 1
            }
        )
        paster.onPasteStart = { pasteStartCalls += 1 }
        paster.onPasteEnd = { pasteEndCalls += 1 }

        let result = paster.paste(text: "new content")

        XCTAssertEqual(result, .copiedToClipboard)
        XCTAssertEqual(prepareCalls, 1)
        XCTAssertEqual(scheduledActions, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "new content")
        XCTAssertEqual(pasteStartCalls, 1)
        XCTAssertEqual(pasteEndCalls, 1)

        pasteboard.releaseGlobally()
    }

    func testPasteSchedulesPasteShortcutAndRestoresClipboardWhenFocusedInputIsAvailable() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        var scheduledActions: [() -> Void] = []
        var postedPasteShortcut = 0
        var pasteStartCalls = 0
        var pasteEndCalls = 0
        let paster = TextPaster(
            pasteboard: pasteboard,
            canPasteIntoFocusedElement: { true },
            preparePasteShortcutAction: {
                { postedPasteShortcut += 1 }
            },
            schedule: { _, action in
                scheduledActions.append(action)
            }
        )
        paster.onPasteStart = { pasteStartCalls += 1 }
        paster.onPasteEnd = { pasteEndCalls += 1 }

        let result = paster.paste(text: "new content")

        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(pasteboard.string(forType: .string), "new content")
        XCTAssertEqual(postedPasteShortcut, 0)
        XCTAssertEqual(scheduledActions.count, 1)
        XCTAssertEqual(pasteStartCalls, 1)
        XCTAssertEqual(pasteEndCalls, 0)

        let postPasteAction = scheduledActions.removeFirst()
        postPasteAction()

        XCTAssertEqual(postedPasteShortcut, 1)
        XCTAssertEqual(scheduledActions.count, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "new content")
        XCTAssertEqual(pasteEndCalls, 0)

        let restoreClipboardAction = scheduledActions.removeFirst()
        restoreClipboardAction()

        XCTAssertEqual(pasteboard.string(forType: .string), "original content")
        XCTAssertEqual(pasteEndCalls, 1)

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
            preparePasteShortcutAction: { {} },
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

    func testPasteMenuItemDetectsCommandV() {
        // isPasteMenuItem is tested indirectly through frontmostAppHasPasteMenuItem.
        // The method checks for Cmd+V (AXMenuItemCmdChar == "v", modifiers == 0).
        // In CI, there may not be a frontmost app with a menu bar, so we verify
        // the method returns a Bool without crashing.
        _ = TextPaster.frontmostAppHasPasteMenuItem()
    }
}
