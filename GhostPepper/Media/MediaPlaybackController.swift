import Foundation
import Darwin

/// Pauses system media playback during recording and resumes when done.
/// Uses the private MediaRemote framework via dynamic loading.
/// Gracefully degrades if the framework is unavailable.
final class MediaPlaybackController {
    private let enabled: () -> Bool

    private typealias SendCommandFunc = @convention(c) (UInt32, UnsafeRawPointer?) -> Bool

    private let frameworkHandle: UnsafeMutableRawPointer?
    private let sendCommand: SendCommandFunc?

    private static let kMRPlay: UInt32 = 0
    private static let kMRPause: UInt32 = 1

    init(enabled: @escaping () -> Bool) {
        self.enabled = enabled

        let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_NOW
        )
        frameworkHandle = handle

        if let handle {
            if let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
                sendCommand = unsafeBitCast(sym, to: SendCommandFunc.self)
            } else {
                sendCommand = nil
            }
        } else {
            sendCommand = nil
        }
    }

    deinit {
        if let frameworkHandle {
            dlclose(frameworkHandle)
        }
    }

    /// Pause media if currently playing. Call before recording starts.
    /// Sends the pause command — it's a no-op if nothing is playing.
    /// Does NOT auto-resume afterward; the user presses play themselves.
    /// This avoids the bug where sending kMRPlay opens Apple Music
    /// even when nothing was playing before recording started.
    func pauseIfPlaying() {
        guard enabled(), let sendCommand else { return }
        _ = sendCommand(Self.kMRPause, nil)
    }

    /// No-op. Kept for API compatibility.
    /// We no longer auto-resume because sending kMRPlay when nothing was
    /// playing causes Apple Music to launch (macOS routes the play command
    /// to the default media handler).
    func resumeIfPaused() {
        // Intentionally empty — user resumes media manually.
    }
}
