import XCTest
@testable import GhostPepper

@MainActor
final class DebugLogStoreTests: XCTestCase {
    func testStoreDropsOldestEntriesWhenCapacityIsExceeded() {
        let store = DebugLogStore(maxEntries: 2)

        store.record(category: .hotkey, message: "first")
        store.record(category: .ocr, message: "second")
        store.record(category: .cleanup, message: "third")

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries.map(\.message), ["second", "third"])
    }

    func testClearRemovesFormattedLogOutput() {
        let store = DebugLogStore(maxEntries: 2)

        store.record(category: .model, message: "loaded")
        store.clear()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.formattedText, "")
    }

    func testSensitiveEntriesAreIgnoredWhenNoDebugViewerIsOpen() {
        let store = DebugLogStore()

        store.recordSensitive(category: .cleanup, message: "full prompt")

        XCTAssertTrue(store.entries.isEmpty)
    }

    func testSensitiveEntriesAreRecordedOnlyWhileDebugViewerIsOpen() {
        let store = DebugLogStore()

        store.beginLiveViewing()
        store.recordSensitive(category: .cleanup, message: "full prompt")
        store.endLiveViewing()
        store.recordSensitive(category: .cleanup, message: "full output")

        XCTAssertEqual(store.entries.map(\.message), ["full prompt"])
    }
}
