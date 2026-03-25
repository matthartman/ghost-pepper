import CoreGraphics
import XCTest
@testable import GhostPepper

final class FocusedElementLocatorTests: XCTestCase {
    func testFirstAvailableTextFallsBackToAncestorValue() {
        let text = FocusedElementLocator.firstAvailableText(
            startingAt: 1,
            valueProvider: { (element: Int) -> String? in
                switch element {
                case 1:
                    return nil
                case 2:
                    return ""
                case 3:
                    return "Jesse"
                default:
                    return nil
                }
            },
            parentProvider: { (element: Int) -> Int? in
                switch element {
                case 1:
                    return 2
                case 2:
                    return 3
                default:
                    return nil
                }
            }
        )

        XCTAssertEqual(text, "Jesse")
    }

    func testFirstAvailableTextUsesFallbackTextWhenDirectValueIsEmpty() {
        let text = FocusedElementLocator.firstAvailableText(
            startingAt: 1,
            valueProvider: { (_: Int) -> String? in nil },
            fallbackTextProvider: { (element: Int) -> String? in
                switch element {
                case 1:
                    return ""
                case 2:
                    return "Kaya"
                default:
                    return nil
                }
            },
            parentProvider: { (element: Int) -> Int? in
                switch element {
                case 1:
                    return 2
                default:
                    return nil
                }
            }
        )

        XCTAssertEqual(text, "Kaya")
    }

    func testFirstFocusedDescendantReturnsFocusedChildWhenRootIsNotFocused() {
        let focusedElement = FocusedElementLocator.firstFocusedDescendant(
            startingAt: 1,
            focusedProvider: { $0 == 3 },
            childrenProvider: { element in
                switch element {
                case 1:
                    return [2, 4]
                case 2:
                    return [3]
                default:
                    return []
                }
            }
        )

        XCTAssertEqual(focusedElement, 3)
    }

    func testWindowReferenceReadsSwiftDictionaryBounds() {
        let locator = FocusedElementLocator()
        let windowList: [[String: Any]] = [[
            kCGWindowOwnerPID as String: NSNumber(value: 42),
            kCGWindowLayer as String: 0,
            kCGWindowAlpha as String: 1.0,
            kCGWindowNumber as String: NSNumber(value: 99),
            kCGWindowBounds as String: [
                "X": 10,
                "Y": 20,
                "Width": 300,
                "Height": 200
            ]
        ]]

        let reference = locator.windowReference(in: windowList, for: 42)

        XCTAssertEqual(reference?.windowID, 99)
        XCTAssertEqual(reference?.frame, CGRect(x: 10, y: 20, width: 300, height: 200))
    }

    func testWindowReferenceIgnoresUnsupportedBoundsValue() {
        let locator = FocusedElementLocator()
        let windowList: [[String: Any]] = [[
            kCGWindowOwnerPID as String: NSNumber(value: 42),
            kCGWindowLayer as String: 0,
            kCGWindowAlpha as String: 1.0,
            kCGWindowNumber as String: NSNumber(value: 99),
            kCGWindowBounds as String: "not a bounds dictionary"
        ]]

        XCTAssertNil(locator.windowReference(in: windowList, for: 42))
    }

    func testObservationEligibilityAllowsMissingOriginalFocusedFrame() {
        let session = PasteSession(
            pastedText: "just see approved it",
            pastedAt: Date(),
            frontmostAppBundleIdentifier: "com.example.app",
            frontmostWindowID: 42,
            frontmostWindowFrame: nil,
            focusedElementFrame: nil,
            focusedElementText: "just see approved it"
        )

        let isEligible = PostPasteLearningObservationProvider.isEligibleObservation(
            for: session,
            currentBundleIdentifier: "com.example.app",
            currentWindowReference: FrontmostWindowReference(
                windowID: 42,
                frame: CGRect(x: 10, y: 20, width: 300, height: 200)
            ),
            currentFocusedFrame: nil
        )

        XCTAssertTrue(isEligible)
    }

    func testObservationEligibilityRejectsDifferentFrontmostApplication() {
        let session = PasteSession(
            pastedText: "just see approved it",
            pastedAt: Date(),
            frontmostAppBundleIdentifier: "com.example.app",
            frontmostWindowID: 42,
            frontmostWindowFrame: nil,
            focusedElementFrame: CGRect(x: 20, y: 40, width: 300, height: 120),
            focusedElementText: "just see approved it"
        )

        let isEligible = PostPasteLearningObservationProvider.isEligibleObservation(
            for: session,
            currentBundleIdentifier: "com.example.other-app",
            currentWindowReference: FrontmostWindowReference(
                windowID: 42,
                frame: CGRect(x: 10, y: 20, width: 300, height: 200)
            ),
            currentFocusedFrame: CGRect(x: 400, y: 400, width: 300, height: 120)
        )

        XCTAssertFalse(isEligible)
    }

    func testObservationEligibilityAllowsWindowAndFocusedFrameDriftWithinSameApp() {
        let session = PasteSession(
            pastedText: "just see approved it",
            pastedAt: Date(),
            frontmostAppBundleIdentifier: "com.example.app",
            frontmostWindowID: 42,
            frontmostWindowFrame: CGRect(x: 10, y: 20, width: 800, height: 600),
            focusedElementFrame: CGRect(x: 20, y: 40, width: 300, height: 120),
            focusedElementText: "just see approved it"
        )

        let isEligible = PostPasteLearningObservationProvider.isEligibleObservation(
            for: session,
            currentBundleIdentifier: "com.example.app",
            currentWindowReference: FrontmostWindowReference(
                windowID: 99,
                frame: CGRect(x: 200, y: 120, width: 900, height: 700)
            ),
            currentFocusedFrame: CGRect(x: 420, y: 400, width: 280, height: 110)
        )

        XCTAssertTrue(isEligible)
    }
}
