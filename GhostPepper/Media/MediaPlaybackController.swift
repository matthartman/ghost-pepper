import Foundation
import Darwin

/// Pauses system media playback during recording and resumes it afterward.
/// Uses the private MediaRemote framework via dynamic loading.
/// Gracefully degrades if the framework is unavailable.
///
/// Auto-resume is safe because we only send the play command when *we* were
/// the ones who paused playback. Before pausing we query the now-playing
/// state; if nothing is playing we don't touch anything, so we never send a
/// stray play command. This avoids the old bug where blindly sending play
/// launched Apple Music even when nothing had been playing before recording.
final class MediaPlaybackController {
    private let enabled: () -> Bool
    private let isPlaying: () -> Bool
    private let sendPause: () -> Void
    private let sendPlay: () -> Void
    private let teardown: () -> Void

    /// True only while we hold a pause we issued and haven't resumed yet.
    private var didPauseMedia = false

    private typealias SendCommandFunc = @convention(c) (UInt32, UnsafeRawPointer?) -> Bool
    private typealias GetIsPlayingFunc = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let kMRPlay: UInt32 = 0
    private static let kMRPause: UInt32 = 1

    /// Designated initializer. The seams are injected so the pause/resume
    /// bookkeeping can be exercised in tests without the private framework.
    init(
        enabled: @escaping () -> Bool,
        isPlaying: @escaping () -> Bool,
        sendPause: @escaping () -> Void,
        sendPlay: @escaping () -> Void,
        teardown: @escaping () -> Void = {}
    ) {
        self.enabled = enabled
        self.isPlaying = isPlaying
        self.sendPause = sendPause
        self.sendPlay = sendPlay
        self.teardown = teardown
    }

    /// Production initializer. Wires the seams to the MediaRemote framework.
    convenience init(enabled: @escaping () -> Bool) {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_NOW
        )

        var sendCommand: SendCommandFunc?
        var getIsPlaying: GetIsPlayingFunc?
        if let handle {
            if let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
                sendCommand = unsafeBitCast(sym, to: SendCommandFunc.self)
            }
            if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
                getIsPlaying = unsafeBitCast(sym, to: GetIsPlayingFunc.self)
            }
        }

        self.init(
            enabled: enabled,
            isPlaying: {
                guard let getIsPlaying else { return false }
                // The framework answers asynchronously; wait briefly so the
                // synchronous pause path can act on the result. Bounded so a
                // hung framework can never stall the start of a recording.
                let semaphore = DispatchSemaphore(value: 0)
                var playing = false
                getIsPlaying(DispatchQueue.global(qos: .userInitiated)) { isPlaying in
                    playing = isPlaying
                    semaphore.signal()
                }
                _ = semaphore.wait(timeout: .now() + 0.5)
                return playing
            },
            sendPause: { _ = sendCommand?(MediaPlaybackController.kMRPause, nil) },
            sendPlay: { _ = sendCommand?(MediaPlaybackController.kMRPlay, nil) },
            teardown: {
                if let handle { dlclose(handle) }
            }
        )
    }

    deinit {
        teardown()
    }

    /// Pause media if currently playing. Call before recording starts.
    /// Records that we issued the pause so `resumeIfPaused()` can undo it.
    /// If nothing is playing (or the feature is disabled) we do nothing, so
    /// no stray play command is sent later.
    func pauseIfPlaying() {
        guard enabled() else { return }
        guard isPlaying() else { return }
        sendPause()
        didPauseMedia = true
    }

    /// Resume media if — and only if — we paused it. Call when recording ends.
    /// Deliberately not gated on `enabled()`: if the setting is toggled off
    /// mid-recording we still restore whatever we changed, so playback never
    /// ends up stuck paused because of us.
    func resumeIfPaused() {
        guard didPauseMedia else { return }
        didPauseMedia = false
        sendPlay()
    }
}
