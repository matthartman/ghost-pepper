import XCTest
@testable import GhostPepper

final class MediaPlaybackControllerTests: XCTestCase {
    /// Builds a controller with injected seams and records the commands it sends.
    private func makeController(
        enabled: Bool,
        isPlaying: Bool
    ) -> (controller: MediaPlaybackController, sent: () -> [String]) {
        var commands: [String] = []
        let controller = MediaPlaybackController(
            enabled: { enabled },
            isPlaying: { isPlaying },
            sendPause: { commands.append("pause") },
            sendPlay: { commands.append("play") }
        )
        return (controller, { commands })
    }

    func testPausesAndResumesWhenMediaIsPlaying() {
        let (controller, sent) = makeController(enabled: true, isPlaying: true)

        controller.pauseIfPlaying()
        XCTAssertEqual(sent(), ["pause"])

        controller.resumeIfPaused()
        XCTAssertEqual(sent(), ["pause", "play"])
    }

    func testDoesNotResumeWhenNothingWasPlaying() {
        // The core guard against the Apple-Music-launch bug: if nothing was
        // playing we never paused, so we must never send a stray play command.
        let (controller, sent) = makeController(enabled: true, isPlaying: false)

        controller.pauseIfPlaying()
        controller.resumeIfPaused()

        XCTAssertEqual(sent(), [])
    }

    func testDoesNothingWhenDisabled() {
        let (controller, sent) = makeController(enabled: false, isPlaying: true)

        controller.pauseIfPlaying()
        controller.resumeIfPaused()

        XCTAssertEqual(sent(), [])
    }

    func testResumeWithoutPriorPauseIsNoOp() {
        let (controller, sent) = makeController(enabled: true, isPlaying: true)

        controller.resumeIfPaused()

        XCTAssertEqual(sent(), [])
    }

    func testResumeIsIdempotent() {
        let (controller, sent) = makeController(enabled: true, isPlaying: true)

        controller.pauseIfPlaying()
        controller.resumeIfPaused()
        controller.resumeIfPaused()

        XCTAssertEqual(sent(), ["pause", "play"])
    }

    func testResumesEvenIfSettingTogglesOffMidRecording() {
        // We paused because the setting was on; if the user turns it off before
        // the recording ends we still restore playback we changed.
        var enabled = true
        var commands: [String] = []
        let controller = MediaPlaybackController(
            enabled: { enabled },
            isPlaying: { true },
            sendPause: { commands.append("pause") },
            sendPlay: { commands.append("play") }
        )

        controller.pauseIfPlaying()
        enabled = false
        controller.resumeIfPaused()

        XCTAssertEqual(commands, ["pause", "play"])
    }
}
