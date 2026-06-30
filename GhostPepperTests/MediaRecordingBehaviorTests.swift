import XCTest
@testable import GhostPepper

final class MediaRecordingBehaviorTests: XCTestCase {
    private let suiteName = "MediaRecordingBehaviorTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testMigrationMapsLegacyPauseEnabledToPause() {
        defaults.set(true, forKey: MediaRecordingBehavior.legacyPauseKey)

        MediaRecordingBehavior.migrateLegacySettingIfNeeded(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: MediaRecordingBehavior.storageKey),
            MediaRecordingBehavior.pause.rawValue
        )
    }

    func testMigrationMapsLegacyPauseDisabledToOff() {
        defaults.set(false, forKey: MediaRecordingBehavior.legacyPauseKey)

        MediaRecordingBehavior.migrateLegacySettingIfNeeded(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: MediaRecordingBehavior.storageKey),
            MediaRecordingBehavior.off.rawValue
        )
    }

    func testMigrationDoesNotOverwriteExistingValue() {
        defaults.set(true, forKey: MediaRecordingBehavior.legacyPauseKey)
        defaults.set(MediaRecordingBehavior.duck.rawValue, forKey: MediaRecordingBehavior.storageKey)

        MediaRecordingBehavior.migrateLegacySettingIfNeeded(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: MediaRecordingBehavior.storageKey),
            MediaRecordingBehavior.duck.rawValue
        )
    }

    func testMigrationIsNoopWithoutLegacyKey() {
        MediaRecordingBehavior.migrateLegacySettingIfNeeded(defaults: defaults)

        XCTAssertNil(defaults.string(forKey: MediaRecordingBehavior.storageKey))
    }

    func testEveryCaseHasADisplayName() {
        for behavior in MediaRecordingBehavior.allCases {
            XCTAssertFalse(behavior.displayName.isEmpty)
        }
    }
}
