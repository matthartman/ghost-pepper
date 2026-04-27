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

        XCTAssertEqual(restoredStore.binding(for: .pushToTalk), .set(pushChord))
        XCTAssertEqual(restoredStore.binding(for: .toggleToTalk), .set(toggleChord))
    }

    func testBindingStoreRejectsDuplicateBindings() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ChordBindingStore(defaults: defaults)
        let chord = try XCTUnwrap(KeyChord(keys: Set([PhysicalKey(keyCode: 54), PhysicalKey(keyCode: 61)])))

        try store.setBinding(chord, for: .pushToTalk)

        XCTAssertThrowsError(try store.setBinding(chord, for: .toggleToTalk))
    }

    func testBindingStoreReturnsUnsetBeforeAnyUserChoice() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ChordBindingStore(defaults: defaults)

        XCTAssertEqual(store.binding(for: .pushToTalk), .unset)
        XCTAssertEqual(store.binding(for: .toggleToTalk), .unset)
        XCTAssertEqual(store.binding(for: .pepperChat), .unset)
    }

    func testBindingStorePersistsClearedStateAcrossReloads() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ChordBindingStore(defaults: defaults)

        store.clearBinding(for: .pushToTalk)
        let restoredStore = ChordBindingStore(defaults: defaults)

        XCTAssertEqual(restoredStore.binding(for: .pushToTalk), .cleared)
    }

    func testSetBindingAfterClearRestoresSetState() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ChordBindingStore(defaults: defaults)
        let chord = try XCTUnwrap(KeyChord(keys: Set([PhysicalKey(keyCode: 54), PhysicalKey(keyCode: 61)])))

        store.clearBinding(for: .pushToTalk)
        try store.setBinding(chord, for: .pushToTalk)

        XCTAssertEqual(store.binding(for: .pushToTalk), .set(chord))
    }

    func testClearedBindingIsNotTreatedAsDuplicate() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = ChordBindingStore(defaults: defaults)
        let chord = try XCTUnwrap(KeyChord(keys: Set([PhysicalKey(keyCode: 54), PhysicalKey(keyCode: 61)])))

        try store.setBinding(chord, for: .pushToTalk)
        store.clearBinding(for: .pushToTalk)

        XCTAssertNoThrow(try store.setBinding(chord, for: .toggleToTalk))
    }
}
