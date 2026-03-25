import XCTest
@testable import GhostPepper

final class ChordBindingStoreTests: XCTestCase {
    private let suiteName = "ChordBindingStoreTests"

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testBindingStorePersistsPushAndToggleChords() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ChordBindingStore(defaults: defaults)
        let pushChord = try XCTUnwrap(KeyChord(keys: Set([PhysicalKey(keyCode: 54), PhysicalKey(keyCode: 61)])))
        let toggleChord = try XCTUnwrap(KeyChord(keys: Set([PhysicalKey(keyCode: 54), PhysicalKey(keyCode: 61), PhysicalKey(keyCode: 49)])))

        try store.setBinding(pushChord, for: .pushToTalk)
        try store.setBinding(toggleChord, for: .toggleToTalk)

        let restoredStore = ChordBindingStore(defaults: defaults)

        XCTAssertEqual(restoredStore.binding(for: .pushToTalk), pushChord)
        XCTAssertEqual(restoredStore.binding(for: .toggleToTalk), toggleChord)
    }

    func testBindingStoreRejectsDuplicateBindings() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ChordBindingStore(defaults: defaults)
        let chord = try XCTUnwrap(KeyChord(keys: Set([PhysicalKey(keyCode: 54), PhysicalKey(keyCode: 61)])))

        try store.setBinding(chord, for: .pushToTalk)

        XCTAssertThrowsError(try store.setBinding(chord, for: .toggleToTalk))
    }
}
