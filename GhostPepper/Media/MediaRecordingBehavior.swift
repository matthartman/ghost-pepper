import Foundation

/// What Ghost Pepper does with other apps' audio while a recording is running.
enum MediaRecordingBehavior: String, CaseIterable, Identifiable {
    /// Leave background audio untouched.
    case off
    /// Send a system pause command so playback stops.
    case pause
    /// Lower the system output volume, then restore it when recording ends.
    case duck

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Do nothing"
        case .pause: return "Pause playback"
        case .duck: return "Lower the volume"
        }
    }
}

extension MediaRecordingBehavior {
    /// UserDefaults key backing the picker in Settings.
    static let storageKey = "mediaRecordingBehavior"
    /// Legacy boolean key this setting replaced.
    static let legacyPauseKey = "pauseMediaWhileRecording"

    /// One-time migration of the old `pauseMediaWhileRecording` boolean.
    /// `true` (the old default) becomes `.pause`, `false` becomes `.off`.
    /// Does nothing once the new key exists.
    static func migrateLegacySettingIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: storageKey) == nil,
              defaults.object(forKey: legacyPauseKey) != nil else {
            return
        }
        let pausedBefore = defaults.bool(forKey: legacyPauseKey)
        let migrated: MediaRecordingBehavior = pausedBefore ? .pause : .off
        defaults.set(migrated.rawValue, forKey: storageKey)
    }
}
