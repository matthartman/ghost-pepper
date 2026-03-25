import XCTest
@testable import GhostPepper

private final class SpyMicLevelMonitor: MicLevelMonitoring {
    var startCallCount = 0
    var stopCallCount = 0
    var restartCallCount = 0

    func start() {
        startCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }

    func restart() {
        restartCallCount += 1
    }
}

@MainActor
final class MicPreviewControllerTests: XCTestCase {
    func testPreviewStartsDisabled() {
        let controller = MicPreviewController(monitor: SpyMicLevelMonitor())

        XCTAssertFalse(controller.isPreviewing)
    }

    func testEnablingPreviewStartsMonitorOnce() {
        let monitor = SpyMicLevelMonitor()
        let controller = MicPreviewController(monitor: monitor)

        controller.setPreviewing(true)
        controller.setPreviewing(true)

        XCTAssertTrue(controller.isPreviewing)
        XCTAssertEqual(monitor.startCallCount, 1)
        XCTAssertEqual(monitor.stopCallCount, 0)
    }

    func testDisablingPreviewStopsMonitor() {
        let monitor = SpyMicLevelMonitor()
        let controller = MicPreviewController(monitor: monitor)

        controller.setPreviewing(true)
        controller.setPreviewing(false)

        XCTAssertFalse(controller.isPreviewing)
        XCTAssertEqual(monitor.startCallCount, 1)
        XCTAssertEqual(monitor.stopCallCount, 1)
    }

    func testRestartIfNeededOnlyRestartsWhenPreviewing() {
        let monitor = SpyMicLevelMonitor()
        let controller = MicPreviewController(monitor: monitor)

        controller.restartIfNeeded()
        controller.setPreviewing(true)
        controller.restartIfNeeded()

        XCTAssertEqual(monitor.restartCallCount, 1)
    }
}
