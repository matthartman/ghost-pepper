import CoreAudio
import Foundation

/// Lowers the system output volume while recording and restores it afterwards.
/// Unlike a hard pause, background audio keeps playing, just quieter.
///
/// Operates on the default output device using the same CoreAudio property
/// style as `AudioDeviceManager`. Falls back to per-channel volume for devices
/// that don't expose a single main volume channel.
final class AudioDucker {
    /// How far the live volume may drift from what we set before we assume the
    /// user changed it themselves and skip the restore.
    private static let manualChangeTolerance: Float32 = 0.05

    private var duckedDevice: AudioDeviceID?
    private var savedVolume: Float32?
    private var appliedVolume: Float32?

    /// Lower the output volume to `fraction` of its current level (clamped to a
    /// sane range). A no-op if already ducked, if there is no usable output
    /// device, or if the device has no settable volume (some external DACs).
    func duck(toFraction fraction: Float32) {
        guard duckedDevice == nil else { return }
        guard let device = Self.defaultOutputDevice(),
              let current = Self.outputVolume(for: device) else { return }

        let clampedFraction = min(max(fraction, 0.01), 1)
        let target = current * clampedFraction
        guard Self.setOutputVolume(target, for: device) else { return }

        duckedDevice = device
        savedVolume = current
        appliedVolume = target
    }

    /// Restore the volume captured by `duck()`. Skips the restore if the user
    /// adjusted the volume while ducked, so we never fight a manual change.
    /// A no-op if we never ducked.
    func restore() {
        guard let device = duckedDevice,
              let saved = savedVolume,
              let applied = appliedVolume else { return }

        duckedDevice = nil
        savedVolume = nil
        appliedVolume = nil

        if let live = Self.outputVolume(for: device),
           abs(live - applied) > Self.manualChangeTolerance {
            return
        }
        _ = Self.setOutputVolume(saved, for: device)
    }

    // MARK: - CoreAudio

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else {
            return nil
        }
        return deviceID
    }

    /// Reads the device's main output volume, averaging the preferred stereo
    /// channels for devices without a master channel.
    private static func outputVolume(for device: AudioDeviceID) -> Float32? {
        if let main = volumeScalar(device: device, element: kAudioObjectPropertyElementMain) {
            return main
        }
        let values = preferredStereoChannels(for: device).compactMap {
            volumeScalar(device: device, element: $0)
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float32(values.count)
    }

    /// Writes the volume to the main element, or to each preferred stereo
    /// channel when the device has no settable main channel.
    @discardableResult
    private static func setOutputVolume(_ volume: Float32, for device: AudioDeviceID) -> Bool {
        let clamped = min(max(volume, 0), 1)
        if setVolumeScalar(clamped, device: device, element: kAudioObjectPropertyElementMain) {
            return true
        }
        var didSet = false
        for channel in preferredStereoChannels(for: device) {
            if setVolumeScalar(clamped, device: device, element: channel) {
                didSet = true
            }
        }
        return didSet
    }

    private static func volumeScalar(
        device: AudioDeviceID,
        element: AudioObjectPropertyElement
    ) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else {
            return nil
        }
        return volume
    }

    private static func setVolumeScalar(
        _ volume: Float32,
        device: AudioDeviceID,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else {
            return false
        }
        var value = volume
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }

    private static func preferredStereoChannels(
        for device: AudioDeviceID
    ) -> [AudioObjectPropertyElement] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var channels = [UInt32](repeating: 0, count: 2)
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &channels) == noErr else {
            return [1, 2]
        }
        return channels.map { AudioObjectPropertyElement($0) }
    }
}
