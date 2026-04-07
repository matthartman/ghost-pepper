import Foundation
import Darwin

/// Controls system media playback during recording sessions.
/// Uses the private MediaRemote framework via dynamic loading.
final class MediaPlaybackController {
    private var didPause = false
    private let enabled: () -> Bool

    private typealias MRMediaRemoteGetNowPlayingInfoFunc = @convention(c) (DispatchQueue, @convention(block) ([String: Any]) -> Void) -> Void
    private typealias MRMediaRemoteSendCommandFunc = @convention(c) (UInt32, UnsafeRawPointer?) -> Bool

    private let frameworkHandle: UnsafeMutableRawPointer?
    private let sendCommand: MRMediaRemoteSendCommandFunc?
    private let getNowPlayingInfo: MRMediaRemoteGetNowPlayingInfoFunc?

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
            if let sendSymbol = dlsym(handle, "MRMediaRemoteSendCommand") {
                sendCommand = unsafeBitCast(sendSymbol, to: MRMediaRemoteSendCommandFunc.self)
            } else {
                sendCommand = nil
            }

            if let nowPlayingSymbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
                getNowPlayingInfo = unsafeBitCast(nowPlayingSymbol, to: MRMediaRemoteGetNowPlayingInfoFunc.self)
            } else {
                getNowPlayingInfo = nil
            }
        } else {
            sendCommand = nil
            getNowPlayingInfo = nil
        }
    }

    deinit {
        if let frameworkHandle {
            dlclose(frameworkHandle)
        }
    }

    /// Pause media if currently playing. Call when recording starts.
    func pauseIfPlaying() {
        guard enabled() else { return }
        guard let getNowPlayingInfo, let sendCommand else { return }

        getNowPlayingInfo(DispatchQueue.main) { [weak self] info in
            let rate: Double
            if let number = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber {
                rate = number.doubleValue
            } else {
                rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
            }
            if rate > 0 {
                _ = sendCommand(Self.kMRPause, nil)
                self?.didPause = true
            }
        }
    }

    /// Resume media if we paused it. Call when recording ends.
    func resumeIfPaused() {
        guard didPause else { return }
        guard let sendCommand else { return }

        didPause = false
        _ = sendCommand(Self.kMRPlay, nil)
    }
}
