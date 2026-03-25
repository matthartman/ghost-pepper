import XCTest
@testable import GhostPepper

@MainActor
final class ScreenRecordingPermissionControllerTests: XCTestCase {
    func testControllerStartsGrantedWhenPermissionAlreadyAvailable() {
        let controller = ScreenRecordingPermissionController(
            hasPermission: { true }
        )

        XCTAssertTrue(controller.isGranted)
    }

    func testControllerStartsDeniedWhenPermissionMissing() {
        let controller = ScreenRecordingPermissionController(
            hasPermission: { false }
        )

        XCTAssertFalse(controller.isGranted)
    }

    func testRefreshUpdatesWhenPermissionIsGrantedInSystemSettings() {
        var hasPermission = false
        let controller = ScreenRecordingPermissionController(
            hasPermission: { hasPermission }
        )

        XCTAssertFalse(controller.isGranted)

        hasPermission = true
        controller.refresh()

        XCTAssertTrue(controller.isGranted)
    }

    func testRefreshKeepsControllerDeniedWhenPermissionRemainsMissing() {
        let controller = ScreenRecordingPermissionController(
            hasPermission: { false }
        )

        controller.refresh()

        XCTAssertFalse(controller.isGranted)
    }

    func testRequestAccessRequestsPermissionAndRefreshesGrantedState() {
        var hasPermission = false
        var requestCount = 0
        let controller = ScreenRecordingPermissionController(
            hasPermission: { hasPermission },
            requestPermission: {
                requestCount += 1
                hasPermission = true
            }
        )

        XCTAssertFalse(controller.isGranted)

        controller.requestAccess()

        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(controller.isGranted)
    }

    func testRequestAccessLeavesControllerDeniedWhenPermissionRemainsMissing() {
        var requestCount = 0
        let controller = ScreenRecordingPermissionController(
            hasPermission: { false },
            requestPermission: {
                requestCount += 1
            }
        )

        controller.requestAccess()

        XCTAssertEqual(requestCount, 1)
        XCTAssertFalse(controller.isGranted)
    }
}
